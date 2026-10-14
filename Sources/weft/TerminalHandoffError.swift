/// Both the application operation and reacquiring the terminal failed.
public struct TerminalHandoffError: Error {
    public let operationError: any Error
    public let resumeError: any Error

    internal init(operationError: any Error, resumeError: any Error) {
        self.operationError = operationError
        self.resumeError = resumeError
    }
}

internal enum TerminalSessionNotification {
    case suspend
    case resume
    case closed
    case deadlineChanged
}
