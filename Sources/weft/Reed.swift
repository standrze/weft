import Foundation
import SystemPackage

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Swift-only POSIX terminal operations beneath weft.
internal enum Reed {
    private static let localeInitialized: Void = { _ = setlocale(LC_CTYPE, "") }()
    #if canImport(Glibc)
        // Swift's Glibc module does not expose wcwidth. Resolve the standard libc
        // function once, with its C calling convention, without adding a C target.
        private typealias WidthFunction = @convention(c) (wchar_t) -> Int32
        private static let systemWidth: WidthFunction? = {
            guard let symbol = dlsym(nil, "wcwidth") else { return nil }
            return unsafeBitCast(symbol, to: WidthFunction.self)
        }()
    #endif
    #if canImport(Glibc)
        // Keep this bounded pair for the process lifetime. A handler on another
        // thread may still be returning during close; never reuse its descriptors.
        nonisolated(unsafe) private static var signalReadDescriptor: Int32 = -1
        nonisolated(unsafe) private static var signalWriteDescriptor: Int32 = -1
    #endif
    private static let ownershipLock = NSLock()
    private static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGWINCH]
    nonisolated(unsafe) private static var originalSettings = termios()
    nonisolated(unsafe) private static var previousActions: [sigaction] = []
    nonisolated(unsafe) private static var active = false
    nonisolated(unsafe) private static var rawModeEnabled = false
    nonisolated(unsafe) private static var receivedSignal: sig_atomic_t = 0

    // No allocation, locks, terminal output, or termios calls are allowed here.
    // Linux additionally writes one byte to a nonblocking self-pipe so readiness
    // works across threads without Dispatch replacing process signal handlers.
    private static let interruptHandler: @convention(c) (Int32) -> Void = { number in
        let savedError = errno
        if number != SIGWINCH { receivedSignal = number }
        #if canImport(Glibc)
            let descriptor = signalWriteDescriptor
            if descriptor >= 0 {
                var wakeup: UInt8 = 1
                while true {
                    let count = withUnsafePointer(to: &wakeup) { Glibc.write(descriptor, $0, 1) }
                    if count < 0, errno == EINTR { continue }
                    break
                }
            }
        #endif
        errno = savedError
    }

    static func begin(rawMode: Bool) throws {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard !active else { throw TerminalError.sessionAlreadyActive }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw TerminalError.requiresTTY
        }
        guard tcgetattr(STDIN_FILENO, &originalSettings) == 0 else {
            throw TerminalError.configurationFailed(operation: "tcgetattr", code: errno)
        }

        #if canImport(Glibc)
            try prepareSignalPipe()
        #endif
        if rawMode {
            var raw = originalSettings
            cfmakeraw(&raw)
            // c_cc is imported as a tuple of different sizes on Darwin and Linux.
            // Index its bytes using the platform's VMIN and VTIME constants.
            withUnsafeMutableBytes(of: &raw.c_cc) { values in
                values[Int(VMIN)] = 0
                values[Int(VTIME)] = 0
            }
            guard applySettings(&raw) == 0 else {
                throw TerminalError.configurationFailed(operation: "tcsetattr", code: errno)
            }
        }
        rawModeEnabled = rawMode
        previousActions = []
        receivedSignal = 0

        do {
            for number in handledSignals {
                var action = sigaction()
                sigemptyset(&action.sa_mask)
                // Avoid SA_RESTART so a signal wakes a blocking input poll.
                action.sa_flags = 0
                #if canImport(Darwin)
                    action.__sigaction_u.__sa_handler = interruptHandler
                #else
                    action.__sigaction_handler.sa_handler = interruptHandler
                #endif
                var previous = sigaction()
                guard sigaction(number, &action, &previous) == 0 else {
                    throw TerminalError.configurationFailed(operation: "sigaction", code: errno)
                }
                previousActions.append(previous)
            }
            active = true
        } catch {
            restoreSettings()
            throw error
        }
    }

    static func end() {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard active else { return }
        restoreSettings()
        active = false
    }

    private static func restoreSettings() {
        if rawModeEnabled {
            _ = applySettings(&originalSettings)
            rawModeEnabled = false
        }
        for (number, saved) in zip(handledSignals, previousActions) {
            var previous = saved
            _ = sigaction(number, &previous, nil)
        }
        previousActions = []
        receivedSignal = 0
    }

    private static func applySettings(_ settings: inout termios) -> Int32 {
        while true {
            let result = tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings)
            if result < 0, errno == EINTR { continue }
            return result
        }
    }

    static var signalNumber: Int32 { receivedSignal }

    static var signalNotificationDescriptor: Int32 {
        #if canImport(Glibc)
            signalReadDescriptor
        #else
            -1
        #endif
    }

    static func drainSignalNotifications() {
        #if canImport(Glibc)
            guard signalReadDescriptor >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 128)
            while true {
                let count = bytes.withUnsafeMutableBytes {
                    Glibc.read(signalReadDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return }
            }
        #endif
    }

    #if canImport(Glibc)
        private static func prepareSignalPipe() throws {
            if signalReadDescriptor >= 0 {
                drainSignalNotifications()
                return
            }
            var descriptors = [Int32](repeating: -1, count: 2)
            guard pipe(&descriptors) == 0 else {
                throw TerminalError.configurationFailed(operation: "pipe", code: errno)
            }
            do {
                for descriptor in descriptors {
                    let flags = fcntl(descriptor, F_GETFL)
                    guard flags >= 0,
                        fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
                    else { throw TerminalError.configurationFailed(operation: "fcntl", code: errno) }
                }
            } catch {
                for descriptor in descriptors { _ = Glibc.close(descriptor) }
                throw error
            }
            signalReadDescriptor = descriptors[0]
            signalWriteDescriptor = descriptors[1]
        }
    #endif

    static func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int {
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        #if canImport(Glibc)
            var descriptors = [
                input,
                pollfd(fd: signalReadDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let result = descriptors.withUnsafeMutableBufferPointer {
                Glibc.poll($0.baseAddress, nfds_t($0.count), timeoutMilliseconds)
            }
            input = descriptors[0]
            if descriptors[1].revents & Int16(POLLIN) != 0 { drainSignalNotifications() }
        #else
            let result = poll(&input, 1, timeoutMilliseconds)
        #endif
        if result < 0 { return errno == EINTR ? 0 : -1 }
        if result == 0 { return 0 }
        if input.revents & Int16(POLLIN) != 0 {
            let count = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                    Darwin.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
                #else
                    Glibc.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
                #endif
            }
            if count < 0 { return errno == EINTR || errno == EAGAIN ? 0 : -1 }
            return count == 0 ? -1 : count
        }
        return input.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 ? -1 : 0
    }

    static func write(_ data: Data) -> Bool {
        do {
            // Swift System handles partial writes and EINTR without changing signal handlers.
            try FileDescriptor.standardOutput.writeAll(data)
            return true
        } catch {
            return false
        }
    }

    static func size() -> Rect {
        var dimensions = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &dimensions) == 0,
            dimensions.ws_col > 0, dimensions.ws_row > 0
        else { return Rect(width: 80, height: 24) }
        return Rect(width: Int(dimensions.ws_col), height: Int(dimensions.ws_row))
    }

    static func width(_ scalar: Unicode.Scalar) -> Int {
        _ = localeInitialized
        #if canImport(Darwin)
            return Int(wcwidth(wchar_t(scalar.value)))
        #else
            return systemWidth.map { Int($0(wchar_t(scalar.value))) } ?? -1
        #endif
    }
}
