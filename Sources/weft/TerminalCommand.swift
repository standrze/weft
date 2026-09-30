import Foundation

/// Terminal controls usable without a renderer.
///
/// Coordinates are zero-based cells.
public enum TerminalCommand: Equatable, Sendable {
    case moveCursor(Point)
    case clearScreen
    case clearLine
    case cursorVisible(Bool)
    case resetStyle

    public var escapeSequence: String {
        switch self {
        case .moveCursor(let point):
            return "\u{1b}[\(max(0, point.y) + 1);\(max(0, point.x) + 1)H"
        case .clearScreen:
            return "\u{1b}[2J\u{1b}[H"
        case .clearLine:
            return "\u{1b}[2K"
        case .cursorVisible(let visible):
            return visible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        case .resetStyle:
            return "\u{1b}[0m"
        }
    }
}

public extension Backend {
    /// Batch commands in one write, preserving their order.
    mutating func execute(_ commands: [TerminalCommand]) throws {
        guard !commands.isEmpty else {
            return
        }
        try write(Data(commands.map(\.escapeSequence).joined().utf8))
    }
}
