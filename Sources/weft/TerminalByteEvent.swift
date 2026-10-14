import Foundation

/// Undecoded input or a change to a terminal session used for byte relaying.
public enum TerminalByteEvent: Equatable, Sendable {
    /// Bytes from one read, including incomplete escape or UTF-8 sequences.
    case bytes(Data)
    case resize(Int, Int)
    case signal(Int)
    /// Ownership was reacquired after a handoff.
    case terminalResumed
}
