import Foundation

/// Writes ANSI terminal output to standard output.
public struct ANSIBackend: Backend {
    public init() {}

    public mutating func write(_ data: Data) throws {
        let written = Reed.write(data)
        guard written else {
            throw TerminalError.outputFailed
        }
    }
}
