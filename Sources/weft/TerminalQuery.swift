import Foundation

/// A read-only terminal query.
///
/// Replies use the session's existing decoded input reader.
public enum TerminalQuery: Hashable, Sendable {
    case cursorPosition
    case foregroundColor
    case backgroundColor
    case kittyKeyboard
    case colorScheme
    /// A DEC private mode number, from 1 through 65535.
    case privateMode(Int)

    internal var sequence: String {
        switch self {
        case .cursorPosition: "\u{1b}[6n"
        case .foregroundColor: "\u{1b}]10;?\u{1b}\\"
        case .backgroundColor: "\u{1b}]11;?\u{1b}\\"
        case .kittyKeyboard: "\u{1b}[?u\u{1b}[c"
        case .colorScheme: "\u{1b}[?996n"
        case let .privateMode(number): "\u{1b}[?\(number)$p"
        }
    }

    internal func matches(_ reply: TerminalReply) -> Bool {
        switch (self, reply) {
        case (.cursorPosition, .cursorPosition), (.foregroundColor, .foregroundColor),
            (.backgroundColor, .backgroundColor), (.kittyKeyboard, .kittyKeyboard),
            (.kittyKeyboard, .kittyKeyboardUnsupported), (.colorScheme, .colorScheme):
            true
        case let (.privateMode(requested), .privateMode(number, _)): requested == number
        default: false
        }
    }
}

/// A reported RGB color, with each channel normalized to 0...65535.
public struct TerminalRGB: Equatable, Sendable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The reported light/dark preference, independent of application theme policy.
public enum TerminalColorScheme: Int, Equatable, Sendable {
    case dark = 1
    case light = 2
}

/// DECRPM state: a reset mode can still be supported.
public enum TerminalModeState: Int, Equatable, Sendable {
    case unrecognized = 0
    case set = 1
    case reset = 2
    case permanentlySet = 3
    case permanentlyReset = 4
}

/// A recognized terminal report.
///
/// Cursor positions are zero-based terminal cells.
public enum TerminalReply: Equatable, Sendable {
    case cursorPosition(Point)
    case foregroundColor(TerminalRGB)
    case backgroundColor(TerminalRGB)
    case kittyKeyboard(flags: UInt32)
    /// Device attributes arrived without a preceding Kitty detection report.
    case kittyKeyboardUnsupported
    case colorScheme(TerminalColorScheme)
    case privateMode(Int, TerminalModeState)
    case primaryDeviceAttributes([Int])
}

/// How a query finished; a timeout leaves support unknown.
public enum TerminalQueryOutcome: Equatable, Sendable {
    case reply(TerminalReply)
    case timedOut
    case cancelled
}

/// Correlates one requested query with its completion event.
public struct TerminalQueryResult: Equatable, Sendable {
    public let id: UUID
    public let query: TerminalQuery
    public let outcome: TerminalQueryOutcome

    internal init(id: UUID, query: TerminalQuery, outcome: TerminalQueryOutcome) {
        self.id = id
        self.query = query
        self.outcome = outcome
    }
}
