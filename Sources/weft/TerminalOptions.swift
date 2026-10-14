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
    /// Request terminal focus reports (DEC private mode 1004).
    ///
    /// Disabled by default.
    public var focusReporting: Bool
    /// Opt into Contour color-scheme change notifications (DEC private mode 2031).
    public var colorSchemeReporting: Bool
    public var keyboardProtocol: TerminalKeyboardProtocol
    /// Maximum UTF-8 bytes retained in a bracketed paste; defaults to 1 MiB.
    public var maximumPasteBytes: Int
    /// Idle milliseconds before a lone legacy Escape becomes a key; defaults to 35.
    ///
    /// Shared by polling and asynchronous events. Zero resolves Escape immediately;
    /// use a longer delay for fragmented input over remote links. Values are clamped
    /// to 0...Int32.max when used. Raw-byte input is unaffected.
    public var escapeTimeoutMilliseconds: Int

    public init(
        rawMode: Bool = true,
        alternateScreen: Bool = false,
        clearScreen: Bool = false,
        clearScrollback: Bool = false,
        hideCursor: Bool = false,
        cursorStyle: TerminalCursorStyle? = nil,
        mouseCapture: Bool = false,
        bracketedPaste: Bool = true,
        focusReporting: Bool = false,
        colorSchemeReporting: Bool = false,
        keyboardProtocol: TerminalKeyboardProtocol = .legacy,
        maximumPasteBytes: Int = 1_048_576,
        escapeTimeoutMilliseconds: Int = 35
    ) {
        self.rawMode = rawMode
        self.alternateScreen = alternateScreen
        self.clearScreen = clearScreen
        self.clearScrollback = clearScrollback
        self.hideCursor = hideCursor
        self.cursorStyle = cursorStyle
        self.mouseCapture = mouseCapture
        self.bracketedPaste = bracketedPaste
        self.focusReporting = focusReporting
        self.colorSchemeReporting = colorSchemeReporting
        self.keyboardProtocol = keyboardProtocol
        self.maximumPasteBytes = max(0, maximumPasteBytes)
        self.escapeTimeoutMilliseconds = max(0, min(Int(Int32.max), escapeTimeoutMilliseconds))
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
        if focusReporting { sequence += "\u{1b}[?1004h" }
        if colorSchemeReporting { sequence += "\u{1b}[?2031h" }
        if keyboardProtocol == .kitty { sequence += "\u{1b}[>31u" }
        return sequence
    }

    internal func leaveSequence(mouseEnabled: Bool, reportMotion: Bool = false) -> String {
        // An input-only relay owns no ANSI modes or style. Preserve the child's
        // balanced output and any enclosing terminal context on close.
        if enterSequence.isEmpty && !mouseEnabled && !reportMotion { return "" }
        var sequence = "\u{1b}[?2026l\u{1b}[0m"
        // Keyboard stacks belong to the current screen: pop before switching back.
        if keyboardProtocol == .kitty { sequence += "\u{1b}[<u" }
        if focusReporting { sequence += "\u{1b}[?1004l" }
        if colorSchemeReporting { sequence += "\u{1b}[?2031l" }
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
