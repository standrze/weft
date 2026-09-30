import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Delivers terminal input and resize events without an idle polling timer.
///
/// Create and consume this source on the main actor. Do not also call the session's
/// `poll` method while it is active. Stop the source before closing its session.
@MainActor
public final class TerminalEvents {
    public let events: AsyncThrowingStream<[InputEvent], Error>

    private let session: TerminalSession
    private let continuation: AsyncThrowingStream<[InputEvent], Error>.Continuation
    private var sources: TerminalEventSources?
    private var escapeTimeout: Task<Void, Never>?
    private var stopped = false

    public init(session: TerminalSession) {
        self.session = session
        let stream = AsyncThrowingStream<[InputEvent], Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        sources = TerminalEventSources(
            signalDescriptor: session.signalNotificationDescriptor,
            onReady: { [weak self] in
                MainActor.assumeIsolated { self?.receiveAvailableEvents() }
            },
            onSignal: { [weak self] number in
                MainActor.assumeIsolated { self?.receiveSignal(number) }
            }
        )
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        receiveAvailableEvents()
    }

    deinit {
        escapeTimeout?.cancel()
        continuation.finish()
    }

    /// Cancels readiness observers and finishes event delivery.
    ///
    /// Safe to repeat.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        sources?.cancel()
        sources = nil
        escapeTimeout?.cancel()
        escapeTimeout = nil
        continuation.finish()
    }

    private func receiveSignal(_ number: Int32) {
        guard !stopped else { return }
        if number == SIGWINCH {
            receiveAvailableEvents()
        } else {
            // Signal sources identify the event directly, independently of input.
            // Poll also checks the recorded signal for synchronous clients.
            continuation.yield([.signal(Int(number))])
        }
    }

    private func receiveAvailableEvents() {
        guard !stopped else { return }
        do {
            let batch = try session.poll(timeoutMilliseconds: 0)
            if !batch.isEmpty { continuation.yield(batch) }
            escapeTimeout?.cancel()
            escapeTimeout = nil
            if session.hasPendingEscape {
                escapeTimeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(40))
                    } catch {
                        return
                    }
                    self?.receiveAvailableEvents()
                }
            }
        } catch {
            continuation.finish(throwing: error)
            stop()
        }
    }
}

/// Dispatch observers are canceled when their owner is released, including error paths.
private final class TerminalEventSources {
    private let sources: [any DispatchSourceProtocol]

    init(
        signalDescriptor: Int32,
        onReady: @escaping @Sendable () -> Void,
        onSignal: @escaping @Sendable (Int32) -> Void
    ) {
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler(handler: onReady)
        var sources: [any DispatchSourceProtocol] = [input]
        #if canImport(Glibc)
            // A self-pipe preserves POSIX handlers and permits reopening sessions.
            // Linux Dispatch signal sources cache and replace those handlers.
            if signalDescriptor >= 0 {
                let signal = DispatchSource.makeReadSource(fileDescriptor: signalDescriptor, queue: .main)
                signal.setEventHandler(handler: onReady)
                sources.append(signal)
            }
        #else
            for number in [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
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
