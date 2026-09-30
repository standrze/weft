/// A failure to open, configure, read from, or write to the terminal.
public enum TerminalError: Error, Equatable {
    case requiresTTY
    case sessionAlreadyActive
    case sessionClosed
    /// A POSIX operation failed; `code` is the captured errno value.
    case configurationFailed(operation: String, code: Int32)
    case inputClosed
    case outputFailed
}
