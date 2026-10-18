#if os(Windows)
    import CWeft
    import Foundation

    /// Native console ownership; input records are converted once into the shared decoder's UTF-8/VT stream.
    internal enum Reed {
        private static let ownershipLock = NSLock()
        nonisolated(unsafe) private static var active = false

        static func begin(rawMode: Bool) throws {
            guard rawMode else {
                throw TerminalError.unsupportedOperation(operation: "Windows canonical console input")
            }
            ownershipLock.lock()
            defer { ownershipLock.unlock() }
            guard !active else { throw TerminalError.sessionAlreadyActive }
            let code = weft_console_begin(rawMode ? 1 : 0)
            guard code == 0 else {
                if code == 6 { throw TerminalError.requiresTTY }
                throw TerminalError.configurationFailed(
                    operation: "configure Windows console", code: Int32(bitPattern: code))
            }
            active = true
        }

        static func end() {
            ownershipLock.lock()
            defer { ownershipLock.unlock() }
            guard active else { return }
            weft_console_end()
            active = false
        }

        static func stopForShell() throws {
            throw TerminalError.unsupportedOperation(operation: "POSIX shell job control")
        }

        static var signalNumber: Int32 { weft_console_signal() }
        static var signalNotificationDescriptor: Int32 { -1 }
        static func drainSignalNotifications() { weft_console_drain_signal() }

        static func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int {
            bytes.withUnsafeMutableBufferPointer {
                Int(weft_console_read($0.baseAddress, $0.count, timeoutMilliseconds))
            }
        }

        static func write(_ data: Data) -> Bool {
            data.withUnsafeBytes {
                weft_console_write($0.bindMemory(to: UInt8.self).baseAddress, $0.count) != 0
            }
        }

        static func size() -> Rect {
            var columns: Int32 = 80
            var rows: Int32 = 24
            weft_console_size(&columns, &rows)
            return Rect(width: Int(columns), height: Int(rows))
        }
    }
#endif
