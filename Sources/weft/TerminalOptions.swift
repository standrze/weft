/// A keyboard protocol explicitly requested by the application.
public enum TerminalKeyboardProtocol: Equatable, Sendable {
    /// Use the terminal's existing keyboard encoding.
    case legacy
    /// Request Kitty's extended key encoding, phases, alternate keys, and associated text.
    case kitty
}

/// Native cursor shapes requested with DECSCUSR; support depends on the terminal.
public enum TerminalCursorStyle: Int, Equatable, Sendable {
    case blinkingBlock = 1
    case steadyBlock = 2
    case blinkingUnderline = 3
    case steadyUnderline = 4
    case blinkingBar = 5
    case steadyBar = 6
}

/// Terminal policies selected by an application when opening a session.
///
/// The defaults enable raw input and bracketed paste without clearing shell history,
/// switching screens, hiding the cursor, or capturing the mouse. Extended keyboard
/// encoding is opt-in because terminal support varies.
public struct TerminalOptions: Equatable, Sendable {
    public var rawMode: Bool
    public var alternateScreen: Bool
    public var clearScreen: Bool
    public var clearScrollback: Bool
    public var hideCursor: Bool
    /// Nil preserves the current shape; an explicit style resets to the conventional default on close.
    public var cursorStyle: TerminalCursorStyle?
    public var mouseCapture: Bool
    public var bracketedPaste: Bool
    public var keyboardProtocol: TerminalKeyboardProtocol

    public init(
        rawMode: Bool = true,
        alternateScreen: Bool = false,
        clearScreen: Bool = false,
        clearScrollback: Bool = false,
        hideCursor: Bool = false,
        cursorStyle: TerminalCursorStyle? = nil,
        mouseCapture: Bool = false,
        bracketedPaste: Bool = true,
        keyboardProtocol: TerminalKeyboardProtocol = .legacy
    ) {
        self.rawMode = rawMode
        self.alternateScreen = alternateScreen
        self.clearScreen = clearScreen
        self.clearScrollback = clearScrollback
        self.hideCursor = hideCursor
        self.cursorStyle = cursorStyle
        self.mouseCapture = mouseCapture
        self.bracketedPaste = bracketedPaste
        self.keyboardProtocol = keyboardProtocol
    }

    internal var enterSequence: String {
        var sequence = ""
        // Clear primary-screen history before entering the alternate buffer. Some
        // terminals allow scrolling into that history from a full-screen application.
        if clearScrollback {
            sequence += "\u{1b}[r\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}[H"
        }
        if alternateScreen { sequence += "\u{1b}[?1049h" }
        if clearScreen { sequence += "\u{1b}[r\u{1b}[H\u{1b}[2J" }
        if hideCursor { sequence += "\u{1b}[?25l" }
        if let cursorStyle { sequence += "\u{1b}[\(cursorStyle.rawValue) q" }
        if mouseCapture { sequence += Self.mouseSequence(enabled: true) }
        if bracketedPaste { sequence += "\u{1b}[?2004h" }
        if keyboardProtocol == .kitty { sequence += "\u{1b}[>31u" }
        return sequence
    }

    internal func leaveSequence(mouseEnabled: Bool, reportMotion: Bool = false) -> String {
        var sequence = "\u{1b}[?2026l\u{1b}[0m"
        // Keyboard stacks belong to the current screen: pop before switching back.
        if keyboardProtocol == .kitty { sequence += "\u{1b}[<u" }
        if bracketedPaste { sequence += "\u{1b}[?2004l" }
        if reportMotion { sequence += "\u{1b}[?1003l" }
        if mouseEnabled { sequence += Self.mouseSequence(enabled: false) }
        if cursorStyle != nil { sequence += "\u{1b}[0 q" }
        if hideCursor { sequence += "\u{1b}[?25h" }
        if alternateScreen { sequence += "\u{1b}[?1049l" }
        return sequence
    }

    internal static func mouseSequence(enabled: Bool) -> String {
        enabled ? "\u{1b}[?1002h\u{1b}[?1006h" : "\u{1b}[?1002l\u{1b}[?1006l"
    }
}
