#if os(Windows)
    import CWeft
    import Dispatch
    import Foundation

    /// A child process hosted by a native Windows ConPTY with bounded byte queues.
    ///
    /// Use one serial execution context. Read output and poll exit status independently;
    /// an exited child may still have final output to consume. Requires Windows 10 1809
    /// or Windows Server 2019. Closing schedules process-tree termination and cleanup.
    public final class PseudoTerminalProcess {
        /// Native DWORD process identifier, preserving its bits when larger than Int32.max.
        public let processIdentifier: Int32
        private var session: OpaquePointer?
        private var exitCode: Int32?

        public init(
            executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
            size: Rect = Rect(width: 80, height: 24)
        ) throws {
            let environment = environment ?? ProcessInfo.processInfo.environment
            guard executable.isFileURL,
                !([executable.path] + arguments).contains(where: { $0.utf16.contains(0) }),
                environment.allSatisfy({
                    !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf16.contains(0) && !$0.value.utf16.contains(0)
                }), Set(environment.keys.map { $0.lowercased() }).count == environment.count
            else { throw TerminalError.configurationFailed(operation: "child arguments", code: 87) }
            let path = Array(executable.path.utf16) + [0]
            var command =
                Array(([executable.path] + arguments).map(Self.quotedArgument).joined(separator: " ").utf16) + [0]
            // CreateProcessW requires a complete case-insensitively sorted, double-NUL block.
            let values = environment.sorted { $0.key.lowercased() < $1.key.lowercased() }
            var block = values.flatMap { Array(($0.key + "=" + $0.value).utf16) + [UInt16(0)] }
            block.append(0)
            if values.isEmpty { block.append(0) }
            guard command.count <= 32_767 else {
                throw TerminalError.configurationFailed(operation: "child command line", code: 206)
            }
            var identifier: UInt32 = 0
            var error: UInt32 = 0
            let handle = path.withUnsafeBufferPointer { path in
                command.withUnsafeMutableBufferPointer { command in
                    block.withUnsafeBufferPointer { block in
                        weft_windows_pty_spawn(
                            path.baseAddress, command.baseAddress, block.baseAddress, nil,
                            Int16(clamping: max(1, size.width)), Int16(clamping: max(1, size.height)), &identifier,
                            &error)
                    }
                }
            }
            guard let handle else { throw Self.failure("CreatePseudoConsole child", error) }
            session = handle
            processIdentifier = Int32(bitPattern: identifier)
        }

        deinit { close() }

        /// Returns at most 8 KiB, empty data when not ready, or nil after all final output is consumed.
        ///
        /// Zero polls immediately; -1 waits for output. Bytes are not decoded.
        public func read(timeoutMilliseconds: Int = 0) throws -> Data? {
            guard let session else { throw TerminalError.sessionClosed }
            var bytes = [UInt8](repeating: 0, count: 8192)
            var count: UInt32 = 0
            var error: UInt32 = 0
            let result = weft_windows_pty_read(
                session, &bytes, UInt32(bytes.count), Int32(clamping: max(-1, timeoutMilliseconds)), &count, &error)
            if result < 0 { throw Self.failure("ConPTY read", error) }
            if result == 2 { return nil }
            return Data(bytes.prefix(Int(count)))
        }

        /// Enqueues at most 8 KiB without blocking; zero means the bounded writer queue is busy.
        ///
        /// Retain and retry the unwritten suffix. OS write failures surface on subsequent operations.
        public func write(_ bytes: Data) throws -> Int {
            guard let session else { throw TerminalError.sessionClosed }
            guard try pollExitStatus() == nil else { throw TerminalError.inputClosed }
            var count: UInt32 = 0
            var error: UInt32 = 0
            let result = bytes.withUnsafeBytes { bytes in
                weft_windows_pty_write(
                    session, bytes.bindMemory(to: UInt8.self).baseAddress,
                    UInt32(min(8192, bytes.count)), &count, &error)
            }
            if result < 0 { throw Self.failure("ConPTY write", error) }
            return Int(count)
        }

        /// Waits for room in the input queue without consuming output.
        public func waitForWritable(timeoutMilliseconds: Int = 16) throws -> Bool {
            guard let session else { throw TerminalError.sessionClosed }
            guard try pollExitStatus() == nil else { throw TerminalError.inputClosed }
            var error: UInt32 = 0
            let result = weft_windows_pty_writable(session, UInt32(clamping: max(0, timeoutMilliseconds)), &error)
            if result < 0 { throw Self.failure("ConPTY writable wait", error) }
            return result != 0
        }

        /// Updates terminal dimensions, clamped to the positive signed 16-bit Windows COORD range.
        public func resize(_ size: Rect) throws {
            guard let session else { throw TerminalError.sessionClosed }
            var error: UInt32 = 0
            if weft_windows_pty_resize(
                session, Int16(clamping: max(1, size.width)),
                Int16(clamping: max(1, size.height)), &error) < 0
            {
                throw Self.failure("ResizePseudoConsole", error)
            }
        }

        /// Returns nil while running, otherwise the native DWORD exit code represented as Int32 bits.
        ///
        /// Output remains readable after this reports exit, including the pseudoconsole's final frame.
        public func pollExitStatus() throws -> Int32? {
            if let exitCode { return exitCode }
            guard let session else { throw TerminalError.sessionClosed }
            var status: UInt32 = 0
            var error: UInt32 = 0
            let result = weft_windows_pty_status(session, &status, &error)
            if result < 0 { throw Self.failure("ConPTY process status", error) }
            guard result > 0 else { return nil }
            exitCode = Int32(bitPattern: status)
            return exitCode
        }

        /// Terminates the owned Job Object tree.
        ///
        /// Signals 15 and 9 map to forced termination
        /// with exit status 128 + signal. Other POSIX signals are unsupported on Windows.
        public func terminate(signal: Int32 = 15) throws {
            guard let session else { throw TerminalError.sessionClosed }
            guard signal == 15 || signal == 9 else {
                throw TerminalError.unsupportedOperation(operation: "POSIX child signals other than 15 or 9")
            }
            var error: UInt32 = 0
            let status = UInt32(128 + signal)
            if weft_windows_pty_terminate(session, status, &error) < 0 {
                throw Self.failure("TerminateJobObject", error)
            }
        }

        /// Releases ownership exactly once.
        ///
        /// Synchronous native pipe teardown runs off the caller's context.
        public func close() {
            guard let session else { return }
            self.session = nil
            let address = UInt(bitPattern: session)
            DispatchQueue.global().async {
                weft_windows_pty_destroy(OpaquePointer(bitPattern: address))
            }
        }

        private static func failure(_ operation: String, _ error: UInt32) -> TerminalError {
            .configurationFailed(operation: operation, code: Int32(bitPattern: error))
        }

        // Microsoft C runtime argv rules: escape quotes and double trailing backslashes.
        // Shell languages still interpret their own explicitly supplied command arguments.
        private static func quotedArgument(_ argument: String) -> String {
            var result: [UInt16] = [34]
            var slashes = 0
            for unit in argument.utf16 {
                if unit == 92 {
                    slashes += 1
                    continue
                }
                result.append(contentsOf: repeatElement(UInt16(92), count: unit == 34 ? slashes * 2 + 1 : slashes))
                result.append(unit)
                slashes = 0
            }
            result.append(contentsOf: repeatElement(UInt16(92), count: slashes * 2))
            result.append(34)
            return String(decoding: result, as: UTF16.self)
        }
    }
#endif
