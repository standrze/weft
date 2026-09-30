import Foundation

/// Owns terminal modes for one interactive session.
///
/// Only one process-wide session may be open at a time. Use it from one serial
/// execution context. Termination signals are delivered as input events; call
/// `close()` on normal exit to restore settings and signal handlers.
public final class TerminalSession {
    /// The policies selected when this session was opened.
    public let options: TerminalOptions
    /// Whether the session currently captures mouse events.
    public private(set) var mouseEnabled: Bool
    /// Whether unpressed pointer motion is currently reported as well as clicks and drags.
    public private(set) var mouseMotionEnabled = false

    private let driver: any TerminalSessionDriver
    private var active = false
    private var decoder = InputDecoder()
    private var lastSize: Rect
    private var lastInputTime = ProcessInfo.processInfo.systemUptime

    /// Opens raw input without changing screens or clearing history by default.
    ///
    /// Pass explicit options for full-screen applications. Raw settings and signal
    /// handlers are restored after initialization failures as well as normal exits.
    public convenience init(options: TerminalOptions = TerminalOptions()) throws {
        try self.init(options: options, driver: SystemTerminalSessionDriver())
    }

    internal init(options: TerminalOptions, driver: any TerminalSessionDriver) throws {
        self.options = options
        self.driver = driver
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
    internal var signalNotificationDescriptor: Int32 { driver.signalNotificationDescriptor }

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
    /// defaults; Weft does not query their previous state. Clearing scrollback is
    /// irreversible. Forced termination such as SIGKILL cannot perform cleanup.
    public func close() {
        guard active else { return }
        active = false
        try? driver.write(
            Data(options.leaveSequence(mouseEnabled: mouseEnabled, reportMotion: mouseMotionEnabled).utf8))
        driver.end()
        mouseEnabled = false
        mouseMotionEnabled = false
    }

    /// Enables or releases mouse capture so the terminal can provide native selection.
    ///
    /// Opt into unpressed pointer motion for hover interactions. It is disabled when
    /// capture is released, and restored to conventional defaults on session close.
    public func setMouseEnabled(_ enabled: Bool, reportMotion: Bool = false) throws {
        guard active else { throw TerminalError.sessionClosed }
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
        guard active else { throw TerminalError.sessionClosed }
        guard text.utf8.count <= 1_048_576 else { return }
        let encodedText = Data(text.utf8).base64EncodedString()
        try driver.write(Data("\u{1b}]52;c;\(encodedText)\u{7}".utf8))
    }

    /// Waits for input and reports terminal resize and termination signals.
    ///
    /// Zero polls without blocking; -1 waits indefinitely. Call again after 35 ms
    /// of idle input to resolve a pending legacy Escape key. Closed sessions throw.
    public func poll(timeoutMilliseconds: Int = 16) throws -> [InputEvent] {
        guard active else { throw TerminalError.sessionClosed }
        driver.drainSignalNotifications()
        if driver.signalNumber != 0 {
            return [.signal(Int(driver.signalNumber))]
        }

        var bytes = [UInt8](repeating: 0, count: 8192)
        // Check size after draining notifications. A resize already waiting must
        // be returned now rather than consumed before an indefinite input wait.
        let resizedBeforeRead = driver.size != lastSize
        let timeout = resizedBeforeRead ? 0 : Int32(clamping: max(-1, timeoutMilliseconds))
        let count = driver.read(&bytes, timeoutMilliseconds: timeout)
        if driver.signalNumber != 0 {
            return [.signal(Int(driver.signalNumber))]
        }
        guard count >= 0 else { throw TerminalError.inputClosed }

        var events: [InputEvent] = []
        let now = ProcessInfo.processInfo.systemUptime
        if count > 0 {
            events = decoder.feed(Array(bytes.prefix(count)))
            lastInputTime = now
        } else if now - lastInputTime >= 0.035 {
            events += decoder.flushEscape()
        }

        let size = driver.size
        if size != lastSize {
            lastSize = size
            events.append(.resize(size.width, size.height))
        }
        return events
    }
}
