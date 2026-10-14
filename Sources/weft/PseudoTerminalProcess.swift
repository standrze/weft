import CWeft
import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A child process with a controlling pseudo-terminal and bounded, nonblocking I/O.
///
/// Use one serial execution context. Drain output and poll exit status independently:
/// a child may exit before its final output is read. Closing terminates a running
/// child group and reaps it off the caller's execution context.
public final class PseudoTerminalProcess {
    public let processIdentifier: Int32
    private var descriptor: Int32
    private var exitCode: Int32?
    private var pendingOutput = Data()
    private var ownsChild = true

    public init(
        executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
        size: Rect = Rect(width: 80, height: 24)
    ) throws {
        let childEnvironment = environment ?? ProcessInfo.processInfo.environment
        guard executable.isFileURL,
            !([executable.path] + arguments).contains(where: { $0.utf8.contains(0) }),
            childEnvironment.allSatisfy({
                !$0.key.contains("=") && !$0.key.isEmpty && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
            })
        else { throw TerminalError.configurationFailed(operation: "child arguments", code: EINVAL) }
        let child = try ReedPTY.spawn(
            executable: executable.path, arguments: arguments, environment: childEnvironment, size: size)
        descriptor = child.descriptor
        processIdentifier = child.pid
    }

    deinit { close() }

    /// Returns at most 8 KiB, empty data when not ready, or nil on terminal EOF.
    ///
    /// Zero polls immediately; -1 waits for readiness. No output bytes are decoded.
    public func read(timeoutMilliseconds: Int = 0) throws -> Data? {
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        if !pendingOutput.isEmpty {
            let packet = Data(pendingOutput.prefix(8192))
            pendingOutput.removeFirst(packet.count)
            return packet
        }
        return try ReedPTY.readAvailable(descriptor, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// Writes at most 8 KiB; zero means backpressure or that the child terminal is still starting.
    ///
    /// Retain and retry the unwritten suffix. This call never waits for writable space.
    public func write(_ bytes: Data) throws -> Int {
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        guard exitCode == nil else { throw TerminalError.inputClosed }
        let foreground = tcgetpgrp(descriptor)
        guard foreground >= 0 else {
            if errno == EINTR { return 0 }
            throw TerminalError.configurationFailed(operation: "PTY foreground group", code: errno)
        }
        // An early VINTR byte is lost if no foreground group can receive it yet.
        guard foreground > 0 else { return 0 }
        return try bytes.withUnsafeBytes { buffer in
            while true {
                let bounded = UnsafeRawBufferPointer(start: buffer.baseAddress, count: min(8192, buffer.count))
                let count = ReedPTY.writeSome(descriptor, buffer: bounded)
                if count >= 0 { return count }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return 0 }
                throw TerminalError.configurationFailed(operation: "PTY write", code: errno)
            }
        }
    }

    /// Waits for writable space without consuming child output or changing terminal modes.
    ///
    /// Returns false on timeout or interruption so the caller can service signals and resize.
    public func waitForWritable(timeoutMilliseconds: Int = 16) throws -> Bool {
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        guard exitCode == nil else { throw TerminalError.inputClosed }
        var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let result = poll(&readiness, 1, Int32(clamping: max(0, timeoutMilliseconds)))
        if result < 0 {
            if errno == EINTR { return false }
            throw TerminalError.configurationFailed(operation: "PTY writable poll", code: errno)
        }
        return result > 0 && readiness.revents & Int16(POLLOUT) != 0
    }

    /// Updates the child terminal dimensions and lets the kernel notify its foreground group.
    public func resize(_ size: Rect) throws {
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        var window = ReedPTY.windowSize(size)
        try ReedPTY.check(ioctl(descriptor, UInt(TIOCSWINSZ), &window), operation: "TIOCSWINSZ")
    }

    /// Returns nil while running, a normal exit code, or 128 plus its terminating signal.
    ///
    /// This also drains final output before reaping. Consume `read()` while polling:
    /// status can be deferred until the bounded output queue has room.
    public func pollExitStatus() throws -> Int32? {
        if let exitCode { return exitCode }
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        // Capture final output before reaping the controlling-terminal leader.
        // Bound retained output and defer reaping if the caller must consume it first.
        while pendingOutput.count <= 1_048_576 - 8192 {
            guard let packet = try ReedPTY.readAvailable(descriptor, timeoutMilliseconds: 0) else { break }
            if packet.isEmpty { break }
            pendingOutput.append(packet)
        }
        if pendingOutput.count > 1_048_576 - 8192 { return nil }
        var status: Int32 = 0
        let result = ReedPTY.wait(processIdentifier, status: &status, options: WNOHANG)
        guard result >= 0 else {
            if errno == ECHILD { ownsChild = false }
            throw TerminalError.configurationFailed(operation: "waitpid", code: errno)
        }
        guard result != 0 else { return nil }
        ownsChild = false
        exitCode = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return exitCode
    }

    /// Sends a signal to the owned child session's process group while its leader is unreaped.
    public func terminate(signal: Int32 = 15) throws {
        guard descriptor >= 0 else { throw TerminalError.sessionClosed }
        guard try pollExitStatus() == nil else { return }
        if kill(-processIdentifier, signal) != 0, errno != ESRCH {
            throw TerminalError.configurationFailed(operation: "kill child group", code: errno)
        }
    }

    /// Releases the PTY exactly once and terminates any still-running owned child group.
    public func close() {
        guard descriptor >= 0 else { return }
        let pid = processIdentifier
        if exitCode == nil { _ = try? pollExitStatus() }
        ReedPTY.closeDescriptor(descriptor)
        descriptor = -1
        guard ownsChild else { return }
        _ = kill(-pid, SIGKILL)
        DispatchQueue.global().async {
            var status: Int32 = 0
            _ = ReedPTY.wait(pid, status: &status, options: 0)
        }
    }
}

/// The POSIX boundary for child terminal descriptors, spawn actions, and reaping.
private enum ReedPTY {
    static func spawn(executable: String, arguments: [String], environment: [String: String], size: Rect)
        throws -> (descriptor: Int32, pid: Int32)
    {
        try check(access(executable, X_OK), operation: "child executable")
        var master: Int32 = -1
        var slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 4096)
        var window = windowSize(size)
        try check(openpty(&master, &slave, &path, nil, &window), operation: "openpty")
        var keepMaster = false
        defer {
            closeDescriptor(slave)
            if !keepMaster { closeDescriptor(master) }
        }
        try prepareTerminal(slave)
        for fd in [master, slave] {
            try check(fcntl(fd, F_SETFD, FD_CLOEXEC), operation: "PTY close-on-exec")
        }
        let flags = fcntl(master, F_GETFL)
        try check(flags, operation: "PTY flags")
        try check(fcntl(master, F_SETFL, flags | O_NONBLOCK), operation: "PTY nonblocking")
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        try checkSpawn(posix_spawn_file_actions_init(&actions), operation: "spawn actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawn(posix_spawnattr_init(&attributes), operation: "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session opens its slave without O_NOCTTY to acquire a controlling terminal.
        var mask = sigset_t()
        sigemptyset(&mask)
        try checkSpawn(posix_spawnattr_setsigmask(&attributes, &mask), operation: "child signal mask")
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGQUIT, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU] {
            sigaddset(&defaults, signal)
        }
        try checkSpawn(posix_spawnattr_setsigdefault(&attributes, &defaults), operation: "child signal defaults")
        let spawnFlags = weft_spawn_setsid_flag() | Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        try checkSpawn(posix_spawnattr_setflags(&attributes, spawnFlags), operation: "spawn session")
        let slavePath = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        try checkSpawn(posix_spawn_file_actions_addclose(&actions, master), operation: "close child master")
        try checkSpawn(posix_spawn_file_actions_addclose(&actions, slave), operation: "close child slave")
        try checkSpawn(posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0), operation: "open child tty")
        for fd: Int32 in [1, 2] {
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, 0, fd), operation: "child tty stdio")
        }
        #if canImport(Darwin)
            // Darwin's spawn actions lack foreground-terminal setup. A minimal
            // noninteractive shell establishes it, then exec preserves the child PID
            // and passes the executable/arguments as literal positional parameters.
            let program = "/bin/sh"
            let childArguments = [program, "-c", #"exec "$@""#, "weft-pty", executable] + arguments
        #else
            let program = executable
            let childArguments = [executable] + arguments
        #endif
        let argv = try allocateStrings(childArguments)
        defer { argv.forEach { free($0) } }
        let env = try allocateStrings(environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value })
        defer { env.forEach { free($0) } }
        var argvPointers = argv.map(Optional.some) + [nil]
        var environmentPointers = env.map(Optional.some) + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, program, &actions, &attributes, &argvPointers, &environmentPointers)
        try checkSpawn(result, operation: "posix_spawn")
        keepMaster = true
        return (master, pid)
    }

    private static func prepareTerminal(_ descriptor: Int32) throws {
        var settings = termios()
        try check(tcgetattr(descriptor, &settings), operation: "child termios")
        settings.c_iflag = tcflag_t(BRKINT | ICRNL | IXON)
        settings.c_oflag = tcflag_t(OPOST | ONLCR)
        settings.c_cflag = (settings.c_cflag & ~tcflag_t(CSIZE | PARENB | PARODD)) | tcflag_t(CREAD | CS8 | HUPCL)
        settings.c_lflag = tcflag_t(ECHO | ICANON | ISIG | IEXTEN | ECHOE | ECHOK)
        let controls: [(Int32, UInt8)] = [
            (VINTR, 3), (VQUIT, 28), (VERASE, 127), (VKILL, 21), (VEOF, 4),
            (VSTART, 17), (VSTOP, 19), (VSUSP, 26), (VWERASE, 23), (VREPRINT, 18),
            (VLNEXT, 22), (VDISCARD, 15), (VMIN, 1), (VTIME, 0),
        ]
        let disabledControl = fpathconf(descriptor, Int32(_PC_VDISABLE))
        guard (0...255).contains(disabledControl) else {
            throw TerminalError.configurationFailed(operation: "child disabled control", code: EINVAL)
        }
        withUnsafeMutableBytes(of: &settings.c_cc) { values in
            for index in values.indices { values[index] = UInt8(disabledControl) }
            for (index, value) in controls where Int(index) < values.count { values[Int(index)] = value }
        }
        try check(tcsetattr(descriptor, TCSANOW, &settings), operation: "child termios defaults")
    }

    static func windowSize(_ size: Rect) -> winsize {
        winsize(
            ws_row: UInt16(clamping: max(1, size.height)), ws_col: UInt16(clamping: max(1, size.width)), ws_xpixel: 0,
            ws_ypixel: 0)
    }

    static func readAvailable(_ descriptor: Int32, timeoutMilliseconds: Int) throws -> Data? {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, Int32(clamping: max(-1, timeoutMilliseconds)))
        if ready == 0 || ready < 0 && errno == EINTR { return Data() }
        try check(ready, operation: "PTY poll")
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = systemRead(descriptor, bytes: &bytes)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 || count < 0 && errno == EIO { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return Data() }
            throw TerminalError.configurationFailed(operation: "PTY read", code: errno)
        }
    }

    static func systemRead(_ descriptor: Int32, bytes: inout [UInt8]) -> Int {
        #if canImport(Darwin)
            Darwin.read(descriptor, &bytes, bytes.count)
        #else
            Glibc.read(descriptor, &bytes, bytes.count)
        #endif
    }

    static func writeSome(_ descriptor: Int32, buffer: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        #else
            Glibc.write(descriptor, buffer.baseAddress, buffer.count)
        #endif
    }

    static func closeDescriptor(_ descriptor: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(descriptor)
        #else
            _ = Glibc.close(descriptor)
        #endif
    }

    static func wait(_ pid: Int32, status: inout Int32, options: Int32) -> Int32 {
        while true {
            let result = waitpid(pid, &status, options)
            if result >= 0 || errno != EINTR { return result }
        }
    }

    static func check(_ result: Int32, operation: String) throws {
        guard result >= 0 else { throw TerminalError.configurationFailed(operation: operation, code: errno) }
    }

    static func checkSpawn(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw TerminalError.configurationFailed(operation: operation, code: result) }
    }

    static func allocateStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>] {
        var pointers: [UnsafeMutablePointer<CChar>] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { free($0) }
                throw TerminalError.configurationFailed(operation: "child strings", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        return pointers
    }
}
