/// A failure to open, configure, read from, or write to the terminal.
public enum TerminalError: Error, Equatable {
    case requiresTTY
    case sessionAlreadyActive
    case sessionClosed
    case sessionSuspended
    /// An asynchronous source already owns decoded input.
    case inputSourceActive
    case invalidQuery
    case queryAlreadyPending
    case tooManyQueries
    /// The platform does not supply the requested operation.
    case unsupportedOperation(operation: String)
    /// A native operation failed; `code` is the captured errno or Windows error code.
    case configurationFailed(operation: String, code: Int32)
    case inputClosed
    /// Decoded and byte input polling cannot share one session.
    case inputModeConflict
    case outputFailed
}
