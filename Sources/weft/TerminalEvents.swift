import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import CWeft
#endif

/// Delivers terminal input and resize events without an idle polling timer.
///
/// Create and consume this source on the main actor. Do not also call the session's
/// `poll` method while it is active. Handoff pauses this source automatically;
/// closing the session or calling `stop()` finishes it.
@MainActor
public final class TerminalEvents {
    public let events: AsyncThrowingStream<[InputEvent], Error>

    private let session: TerminalSession
    private let continuation: AsyncThrowingStream<[InputEvent], Error>.Continuation
    private var sources: TerminalEventSources?
    private var deadlineTask: Task<Void, Never>?
    private var stopped = false
    private var paused = false
    private var observerID: UUID?
    private var generation = UUID()
    private var lastSignalDelivered: Int?

    public init(session: TerminalSession) {
        self.session = session
        let stream = AsyncThrowingStream<[InputEvent], Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        do {
            observerID = try session.attachEventSource { [weak self] notification in
                MainActor.assumeIsolated { self?.sessionChanged(notification) }
            }
            paused = session.isSuspended
            if !paused { beginObserving() }
        } catch {
            stopped = true
            continuation.finish(throwing: error)
        }
    }

    isolated deinit {
        if let observerID { session.detachEventSource(observerID) }
        deadlineTask?.cancel()
        continuation.finish()
    }

    /// Cancels readiness observers and finishes event delivery.
    ///
    /// Safe to repeat.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        pauseInput()
        if let observerID { session.detachEventSource(observerID) }
        observerID = nil
        continuation.finish()
    }

    private func pauseInput() {
        paused = true
        generation = UUID()
        sources?.cancel()
        sources = nil
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func sessionChanged(_ notification: TerminalSessionNotification) {
        guard !stopped else { return }
        switch notification {
        case .suspend: pauseInput()
        case .resume:
            paused = false
            lastSignalDelivered = nil
            beginObserving()
        case .closed: stop()
        case .deadlineChanged: scheduleDeadline()
        }
    }

    private func beginObserving() {
        let currentGeneration = generation
        do {
            sources = try TerminalEventSources(
                usesNativeConsole: session.usesNativeConsoleReadiness,
                inputDescriptor: session.inputNotificationDescriptor,
                signalDescriptor: session.signalNotificationDescriptor,
                onReady: { [weak self] in
                    MainActor.assumeIsolated {
                        guard self?.generation == currentGeneration else { return }
                        self?.receiveAvailableEvents()
                    }
                },
                onFailure: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == currentGeneration else { return }
                        self.continuation.finish(throwing: TerminalError.inputClosed)
                        self.stop()
                    }
                },
                onSignal: { [weak self] number in
                    MainActor.assumeIsolated {
                        guard self?.generation == currentGeneration else { return }
                        self?.receiveSignal(number)
                    }
                }
            )
        } catch {
            continuation.finish(throwing: error)
            stop()
            return
        }
        receiveAvailableEvents()
    }

    private func yield(_ batch: [InputEvent]) {
        let filtered = batch.filter { event in
            if case let .signal(number) = event {
                guard lastSignalDelivered != number else { return false }
                lastSignalDelivered = number
            }
            return true
        }
        if !filtered.isEmpty { continuation.yield(filtered) }
    }

    private func receiveSignal(_ number: Int32) {
        guard !stopped && !paused else { return }
        #if !os(Windows)
            if number == SIGWINCH {
                receiveAvailableEvents()
                return
            }
        #endif
        // Signal sources identify the event directly, independently of input.
        // Poll also checks the recorded signal for synchronous clients.
        yield([.signal(Int(number))])
    }

    private func receiveAvailableEvents() {
        guard !stopped && !paused else { return }
        do {
            yield(try session.pollFromEventSource())
            scheduleDeadline()
        } catch {
            continuation.finish(throwing: error)
            stop()
        }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard !stopped && !paused, let remaining = session.nextEventTimeoutMilliseconds else { return }
        let currentGeneration = generation
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(remaining)) } catch { return }
            guard self?.generation == currentGeneration else { return }
            self?.receiveAvailableEvents()
        }
    }
}

#if !os(Windows)
    /// Dispatch observers are canceled when their owner is released, including error paths.
    private final class TerminalEventSources {
        private let sources: [any DispatchSourceProtocol]

        init(
            usesNativeConsole: Bool,
            inputDescriptor: Int32,
            signalDescriptor: Int32,
            onReady: @escaping @Sendable () -> Void,
            onFailure: @escaping @Sendable () -> Void,
            onSignal: @escaping @Sendable (Int32) -> Void
        ) throws {
            var sources: [any DispatchSourceProtocol] = []
            if inputDescriptor >= 0 {
                let input = DispatchSource.makeReadSource(fileDescriptor: inputDescriptor, queue: .main)
                input.setEventHandler(handler: onReady)
                sources.append(input)
            }
            #if canImport(Glibc)
                // A self-pipe preserves POSIX handlers and permits reopening sessions.
                // Linux Dispatch signal sources cache and replace those handlers.
                if signalDescriptor >= 0 {
                    let signal = DispatchSource.makeReadSource(fileDescriptor: signalDescriptor, queue: .main)
                    signal.setEventHandler(handler: onReady)
                    sources.append(signal)
                }
            #else
                for number in inputDescriptor >= 0 ? Reed.handledSignals : [] {
                    let signal = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    signal.setEventHandler { onSignal(number) }
                    // Registration is asynchronous. A signal may reach Reed before its
                    // Dispatch observer is installed, so consume any recorded signal then.
                    signal.setRegistrationHandler(handler: onReady)
                    sources.append(signal)
                }
            #endif
            self.sources = sources
            for source in sources { source.resume() }
        }

        func cancel() {
            for source in sources { source.cancel() }
        }

        deinit { cancel() }
    }

#else
    /// One blocking Win32 wait, followed by a main-queue acknowledgment before rearming.
    ///
    /// The waiting thread observes readiness only; the session remains the sole input reader.
    private final class TerminalEventSources {
        private let state: NativeConsoleWaiter?

        init(
            usesNativeConsole: Bool, inputDescriptor: Int32, signalDescriptor: Int32,
            onReady: @escaping @Sendable () -> Void,
            onFailure: @escaping @Sendable () -> Void,
            onSignal: @escaping @Sendable (Int32) -> Void
        ) throws {
            guard usesNativeConsole else {
                state = nil
                return
            }
            guard let pointer = weft_console_waiter_create() else {
                throw TerminalError.configurationFailed(operation: "create Windows console readiness", code: 0)
            }
            let state = NativeConsoleWaiter(pointer: pointer)
            self.state = state
            DispatchQueue.global(qos: .userInitiated).async {
                while !state.isCancelled {
                    let result = weft_console_waiter_wait(state.pointer)
                    guard result != 0 else { return }
                    DispatchQueue.main.async {
                        if !state.isCancelled {
                            if result > 0 { onReady() } else { onFailure() }
                        }
                        state.acknowledgment.signal()
                    }
                    state.acknowledgment.wait()
                    if result < 0 { return }
                }
            }
        }

        func cancel() { state?.cancel() }
        deinit { cancel() }
    }

    private final class NativeConsoleWaiter: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let acknowledgment = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var cancelled = false

        init(pointer: UnsafeMutableRawPointer) { self.pointer = pointer }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            weft_console_waiter_cancel(pointer)
            acknowledgment.signal()
            lock.unlock()
        }

        deinit { weft_console_waiter_destroy(pointer) }
    }
#endif
