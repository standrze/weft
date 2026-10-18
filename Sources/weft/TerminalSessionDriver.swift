import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The terminal boundary used by a session; a fake driver exercises failure cleanup.
internal protocol TerminalSessionDriver {
    func begin(rawMode: Bool) throws
    func end()
    func write(_ data: Data) throws
    func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int
    var size: Rect { get }
    var signalNumber: Int32 { get }
    var signalNotificationDescriptor: Int32 { get }
    var inputDescriptor: Int32 { get }
    /// Native Windows readiness is only used by the system driver, never fake drivers.
    var usesNativeConsoleReadiness: Bool { get }
    func drainSignalNotifications()
}

extension TerminalSessionDriver {
    var signalNotificationDescriptor: Int32 { -1 }
    var inputDescriptor: Int32 {
        #if os(Windows)
            -1
        #else
            STDIN_FILENO
        #endif
    }
    var usesNativeConsoleReadiness: Bool { false }
    func drainSignalNotifications() {}
}

internal struct SystemTerminalSessionDriver: TerminalSessionDriver {
    func begin(rawMode: Bool) throws { try Reed.begin(rawMode: rawMode) }
    func end() { Reed.end() }

    func write(_ data: Data) throws {
        guard Reed.write(data) else { throw TerminalError.outputFailed }
    }

    func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int {
        Reed.read(&bytes, timeoutMilliseconds: timeoutMilliseconds)
    }

    var usesNativeConsoleReadiness: Bool {
        #if os(Windows)
            true
        #else
            false
        #endif
    }
    var size: Rect { Reed.size() }
    var signalNumber: Int32 { Reed.signalNumber }
    var signalNotificationDescriptor: Int32 { Reed.signalNotificationDescriptor }
    func drainSignalNotifications() { Reed.drainSignalNotifications() }
}
