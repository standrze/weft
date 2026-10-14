import Foundation

/// Owns terminal modes for one interactive session.
///
/// Only one process-wide session may own the terminal at a time. Use it from one serial
/// execution context. Termination signals are delivered as input events; call
/// `close()` on normal exit to restore settings and signal handlers.
/// When `TerminalEvents` is attached, use the session on the main actor as well.
public final class TerminalSession {
    /// The policies selected when this session was opened.
    public let options: TerminalOptions
    /// Whether the session currently captures mouse events.
    public private(set) var mouseEnabled: Bool
    /// Whether unpressed pointer motion is currently reported as well as clicks and drags.
    public private(set) var mouseMotionEnabled = false

    private let driver: any TerminalSessionDriver
    private var active = false
    private var closed = false
    /// True while raw mode, ANSI modes, and input observers have been released.
    public private(set) var isSuspended = false
    private var suspendedMouse: (enabled: Bool, motion: Bool)?
    private var resumeEventPending = false
    private var eventObserver: (id: UUID, notify: (TerminalSessionNotification) -> Void)?
    private let queries: TerminalQueryQueue
    private var decoder: InputDecoder
    private enum InputMode { case decoded, bytes }
    private var inputMode: InputMode?
    private var lastSize: Rect
    private let clock: () -> TimeInterval
    private var lastInputTime: TimeInterval

    /// Opens raw input without changing screens or clearing history by default.
    ///
    /// Pass explicit options for full-screen applications. Raw settings and signal
    /// handlers are restored after initialization failures as well as normal exits.
    public convenience init(options: TerminalOptions = TerminalOptions()) throws {
        try self.init(options: options, driver: SystemTerminalSessionDriver())
    }

    internal init(
        options: TerminalOptions, driver: any TerminalSessionDriver,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        self.options = options
        decoder = InputDecoder(maximumPasteBytes: options.maximumPasteBytes, terminalReplies: true)
        queries = TerminalQueryQueue(clock: clock)
        self.driver = driver
        self.clock = clock
        lastInputTime = clock()
        mouseEnabled = options.mouseCapture
        lastSize = driver.size
        try driver.begin(rawMode: options.rawMode)
        active = true

        do {
            try driver.write(Data(options.enterSequence.utf8))
        } catch {
            // Output may have failed after writing only part of the entry sequence.
            // Attempt the inverse sequence before restoring POSIX terminal settings.
            close()
            throw error
        }
    }

    internal var hasPendingEscape: Bool { decoder.hasPendingEscape }
    internal var pendingEscapeTimeoutMilliseconds: Int? {
        guard decoder.hasPendingEscape else { return nil }
        let delay = max(0, min(Int(Int32.max), options.escapeTimeoutMilliseconds))
        let elapsed = max(0, (clock() - lastInputTime) * 1000)
        return Int(max(0, Double(delay) - elapsed).rounded(.up))
    }
    internal var signalNotificationDescriptor: Int32 { driver.signalNotificationDescriptor }
    internal var inputNotificationDescriptor: Int32 { driver.inputDescriptor }
    internal var nextEventTimeoutMilliseconds: Int? {
        if resumeEventPending { return 0 }
        return [pendingEscapeTimeoutMilliseconds, queries.nextTimeoutMilliseconds].compactMap { $0 }.min()
    }

    deinit {
        close()
    }

    /// Returns the terminal dimensions in cells, with an 80-by-24 fallback.
    public static func size() -> Rect {
        Reed.size()
    }

    /// Restores modes enabled by the session, terminal settings, and signal handlers.
    ///
    /// Calling this more than once has no effect. ANSI modes return to conventional
    /// defaults; weft does not query their previous state. Clearing scrollback is
    /// irreversible. Forced termination such as SIGKILL cannot perform cleanup.
    public func close() {
        guard !closed else { return }
        closed = true
        let observer = eventObserver
        eventObserver = nil
        observer?.notify(.closed)
        if active {
            active = false
            try? driver.write(
                Data(options.leaveSequence(mouseEnabled: mouseEnabled, reportMotion: mouseMotionEnabled).utf8))
            driver.end()
        }
        isSuspended = false
        suspendedMouse = nil
        queries.cancelAll()
        mouseEnabled = false
        mouseMotionEnabled = false
    }

    /// Releases terminal ownership for an editor, pager, or shell.
    ///
    /// Safe to repeat.
    /// Input sources pause automatically. Pending queries are cancelled, and partial
    /// input is discarded at this ownership boundary. Even if ANSI output fails,
    /// POSIX settings are restored and the session remains suspended.
    public func suspend() throws {
        guard !closed else { throw TerminalError.sessionClosed }
        guard !isSuspended else { return }
        eventObserver?.notify(.suspend)
        suspendedMouse = (mouseEnabled, mouseMotionEnabled)
        queries.cancelAll()
        decoder = InputDecoder(maximumPasteBytes: options.maximumPasteBytes, terminalReplies: true)
        defer {
            driver.end()
            active = false
            isSuspended = true
            mouseEnabled = false
            mouseMotionEnabled = false
        }
        try driver.write(Data(options.leaveSequence(mouseEnabled: mouseEnabled, reportMotion: mouseMotionEnabled).utf8))
    }

    /// Reacquires the terminal and resumes input, then delivers `.terminalResumed` for a redraw.
    ///
    /// Does not repeat explicit screen/scrollback clearing. If acquisition or output
    /// fails, the session remains suspended and another attempt is permitted.
    public func resume() throws {
        guard !closed else { throw TerminalError.sessionClosed }
        guard isSuspended else { return }
        let mouse = suspendedMouse ?? (enabled: options.mouseCapture, motion: false)
        try driver.begin(rawMode: options.rawMode)
        var resumedOptions = options
        resumedOptions.clearScreen = false
        resumedOptions.clearScrollback = false
        resumedOptions.mouseCapture = mouse.enabled
        var entry = resumedOptions.enterSequence
        if mouse.motion { entry += "\u{1b}[?1002l\u{1b}[?1003h\u{1b}[?1006h" }
        do {
            try driver.write(Data(entry.utf8))
        } catch {
            try? driver.write(Data(options.leaveSequence(mouseEnabled: mouse.enabled, reportMotion: mouse.motion).utf8))
            driver.end()
            throw error
        }
        active = true
        isSuspended = false
        mouseEnabled = mouse.enabled
        mouseMotionEnabled = mouse.motion
        lastInputTime = clock()
        resumeEventPending = true
        eventObserver?.notify(.resume)
    }

    /// Runs application-selected work with normal terminal settings and resumes on success or failure.
    ///
    /// Use a synchronous operation that finishes before returning. A child process
    /// may inherit the terminal here; command selection and process waiting belong
    /// to the application. If both work and resume fail, both errors are retained.
    public func withSuspendedTerminal<Value>(_ operation: () throws -> Value) throws -> Value {
        try requireActive()
        try suspend()
        let result: Result<Value, any Error>
        do { result = .success(try operation()) } catch { result = .failure(error) }
        do {
            try resume()
        } catch {
            if case let .failure(operationError) = result {
                throw TerminalHandoffError(operationError: operationError, resumeError: error)
            }
            throw error
        }
        return try result.get()
    }

    /// Releases the terminal, sends SIGTSTP to the process, and resumes after the shell continues the job.
    ///
    /// Applications choose when to call this, such as for Ctrl-Z or a SIGTSTP event.
    /// Actual suspension depends on shell job control and the prior SIGTSTP disposition.
    public func suspendToShell() throws {
        try withSuspendedTerminal { try Reed.stopForShell() }
    }

    /// Sends a bounded query and delivers its result through `poll` or `TerminalEvents`.
    ///
    /// One request per query may be pending; at most 32 unconsumed requests/results
    /// are retained. Zero expires immediately. Protocols have no request IDs on the
    /// wire: consume results before retrying and allow for late replies after timeout.
    @discardableResult
    public func requestQuery(_ query: TerminalQuery, timeoutMilliseconds: Int = 250) throws -> UUID {
        try requireActive()
        guard inputMode == nil || inputMode == .decoded else { throw TerminalError.inputModeConflict }
        let id = try queries.request(query, timeoutMilliseconds: timeoutMilliseconds, write: driver.write)
        inputMode = .decoded
        eventObserver?.notify(.deadlineChanged)
        return id
    }

    /// Cancels a pending query; its completion event is delivered by the decoded reader.
    @discardableResult
    public func cancelQuery(_ id: UUID) -> Bool {
        let cancelled = queries.cancel(id)
        if cancelled { eventObserver?.notify(.deadlineChanged) }
        return cancelled
    }

    internal func attachEventSource(_ notify: @escaping (TerminalSessionNotification) -> Void) throws -> UUID {
        guard !closed else { throw TerminalError.sessionClosed }
        guard eventObserver == nil else { throw TerminalError.inputSourceActive }
        guard inputMode != .bytes else { throw TerminalError.inputModeConflict }
        inputMode = .decoded
        let id = UUID()
        eventObserver = (id, notify)
        return id
    }

    internal func detachEventSource(_ id: UUID) {
        if eventObserver?.id == id { eventObserver = nil }
    }

    private func requireActive() throws {
        guard !closed else { throw TerminalError.sessionClosed }
        guard !isSuspended else { throw TerminalError.sessionSuspended }
        guard active else { throw TerminalError.sessionClosed }
    }

    /// Enables or releases mouse capture so the terminal can provide native selection.
    ///
    /// Opt into unpressed pointer motion for hover interactions. It is disabled when
    /// capture is released, and restored to conventional defaults on session close.
    public func setMouseEnabled(_ enabled: Bool, reportMotion: Bool = false) throws {
        try requireActive()
        let motion = enabled && reportMotion
        guard enabled != mouseEnabled || motion != mouseMotionEnabled else { return }
        // Clear any-motion mode before changing tracking modes, including rollback
        // after a partially written escape sequence.
        let resetMotion = motion || mouseMotionEnabled ? "\u{1b}[?1003l" : ""
        func sequence(enabled: Bool, motion: Bool) -> String {
            if enabled && motion {
                return resetMotion + "\u{1b}[?1002l\u{1b}[?1003h\u{1b}[?1006h"
            }
            return resetMotion + TerminalOptions.mouseSequence(enabled: enabled)
        }
        do {
            try driver.write(Data(sequence(enabled: enabled, motion: motion).utf8))
            mouseEnabled = enabled
            mouseMotionEnabled = motion
        } catch {
            try? driver.write(Data(sequence(enabled: mouseEnabled, motion: mouseMotionEnabled).utf8))
            throw error
        }
    }

    /// Requests clipboard copying through OSC 52, when supported by the terminal.
    ///
    /// Requests larger than one mebibyte of UTF-8 text are ignored.
    public func copyUsingOSC52(_ text: String) throws {
        try requireActive()
        guard text.utf8.count <= 1_048_576 else { return }
        let encodedText = Data(text.utf8).base64EncodedString()
        try driver.write(Data("\u{1b}]52;c;\(encodedText)\u{7}".utf8))
    }

    /// Writes bytes unchanged, without interpreting terminal control sequences.
    ///
    /// The caller owns protocols emitted through this method and must balance their modes.
    public func writeBytes(_ bytes: Data) throws {
        try requireActive()
        try driver.write(bytes)
    }

    /// Receives undecoded input for a terminal relay, plus resize and termination events.
    ///
    /// Zero polls without blocking; -1 waits indefinitely. Escape, paste, UTF-8 and
    /// extended keyboard bytes retain their original encoding and chunk boundaries.
    /// A session chooses bytes or decoded input on its first poll and cannot mix them.
    /// With `readInput` false, poll only resize/termination without consuming stdin
    /// or waiting. This lets a relay respect child backpressure with bounded buffers.
    public func pollBytes(timeoutMilliseconds: Int = 16, readInput: Bool = true) throws -> [TerminalByteEvent] {
        guard eventObserver == nil else { throw TerminalError.inputSourceActive }
        try selectInputMode(.bytes)
        var events: [TerminalByteEvent] = []
        if resumeEventPending {
            resumeEventPending = false
            events.append(.terminalResumed)
        }
        driver.drainSignalNotifications()
        if driver.signalNumber != 0 { return events + [.signal(Int(driver.signalNumber))] }
        if !readInput {
            let size = driver.size
            guard size != lastSize else { return events }
            lastSize = size
            return events + [.resize(size.width, size.height)]
        }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let resizedBeforeRead = driver.size != lastSize
        let timeout = resizedBeforeRead || !events.isEmpty ? 0 : Int32(clamping: max(-1, timeoutMilliseconds))
        let count = driver.read(&bytes, timeoutMilliseconds: timeout)
        if driver.signalNumber != 0 { return events + [.signal(Int(driver.signalNumber))] }
        guard count >= 0 else { throw TerminalError.inputClosed }
        if count > 0 { events.append(.bytes(Data(bytes.prefix(count)))) }
        let size = driver.size
        if size != lastSize {
            lastSize = size
            events.append(.resize(size.width, size.height))
        }
        return events
    }

    private func selectInputMode(_ mode: InputMode) throws {
        try requireActive()
        guard inputMode == nil || inputMode == mode else { throw TerminalError.inputModeConflict }
        inputMode = mode
    }

    /// Waits for input and reports terminal resize and termination signals.
    ///
    /// Zero polls without blocking; -1 waits indefinitely except for pending queries
    /// or a legacy Escape deadline. Escape uses `escapeTimeoutMilliseconds`.
    /// Closed sessions throw.
    public func poll(timeoutMilliseconds: Int = 16) throws -> [InputEvent] {
        guard eventObserver == nil else { throw TerminalError.inputSourceActive }
        return try pollDecoded(timeoutMilliseconds: timeoutMilliseconds)
    }

    internal func pollFromEventSource() throws -> [InputEvent] {
        try pollDecoded(timeoutMilliseconds: 0)
    }

    private func pollDecoded(timeoutMilliseconds: Int) throws -> [InputEvent] {
        try selectInputMode(.decoded)
        queries.expire()
        driver.drainSignalNotifications()
        if driver.signalNumber != 0 {
            return pendingSessionEvents() + [.signal(Int(driver.signalNumber))]
        }

        var bytes = [UInt8](repeating: 0, count: 8192)
        // Check size after draining notifications. A resize already waiting must
        // be returned now rather than consumed before an indefinite input wait.
        let resizedBeforeRead = driver.size != lastSize
        let remainingEscapeTime = pendingEscapeTimeoutMilliseconds
        let escapeExpiredBeforeRead = remainingEscapeTime == 0
        var timeout = resizedBeforeRead ? 0 : Int32(clamping: max(-1, timeoutMilliseconds))
        if let remaining = nextEventTimeoutMilliseconds {
            timeout = timeout < 0 ? Int32(remaining) : min(timeout, Int32(remaining))
        }
        let count = driver.read(&bytes, timeoutMilliseconds: timeout)
        if driver.signalNumber != 0 {
            return pendingSessionEvents() + [.signal(Int(driver.signalNumber))]
        }
        guard count >= 0 else { throw TerminalError.inputClosed }
        queries.expire()

        // A caller that resumes polling after the deadline must not turn newly
        // arrived text into Alt+key by joining it to an already expired prefix.
        var events: [InputEvent] = escapeExpiredBeforeRead ? decoder.flushEscape() : []
        events += pendingSessionEvents()
        if count > 0 {
            events += queries.resolve(
                decoder.feed(Array(bytes.prefix(count))), colorSchemeReporting: options.colorSchemeReporting)
            lastInputTime = clock()
        }
        if pendingEscapeTimeoutMilliseconds == 0 {
            events += decoder.flushEscape()
        }
        queries.expire()
        events += queries.drainCompletions()

        let size = driver.size
        if size != lastSize {
            lastSize = size
            events.append(.resize(size.width, size.height))
        }
        return events
    }

    private func pendingSessionEvents() -> [InputEvent] {
        var events = queries.drainCompletions()
        if resumeEventPending {
            resumeEventPending = false
            events.append(.terminalResumed)
        }
        return events
    }
}
