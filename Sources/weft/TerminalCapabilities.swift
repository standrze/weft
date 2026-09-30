import Foundation

/// The color encodings a terminal is expected to understand.
public enum TerminalColorDepth: String, Equatable, Sendable {
    case monochrome
    case ansi16
    case ansi256
    case trueColor
}

/// A conservative, environment-inferred terminal profile.
///
/// Environment variables are hints rather than proof, especially across SSH or
/// tmux. Applications can override individual choices after a successful probe
/// or a user setting. Unsupported or unknown optional protocols default off.
public struct TerminalCapabilities: Equatable, Sendable {
    public var colorDepth: TerminalColorDepth
    public var synchronizedOutput: Bool
    public var hyperlinks: Bool
    public var kittyKeyboard: Bool

    public init(
        colorDepth: TerminalColorDepth = .ansi16,
        synchronizedOutput: Bool = false,
        hyperlinks: Bool = false,
        kittyKeyboard: Bool = false
    ) {
        self.colorDepth = colorDepth
        self.synchronizedOutput = synchronizedOutput
        self.hyperlinks = hyperlinks
        self.kittyKeyboard = kittyKeyboard
    }

    /// Infers a safe output profile from the process environment.
    public static func inferred(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let term = (environment["TERM"] ?? "").lowercased()
        let program = (environment["TERM_PROGRAM"] ?? "").lowercased()
        let colorTerm = (environment["COLORTERM"] ?? "").lowercased()
        let multiplexed = environment["TMUX"] != nil || term.hasPrefix("screen")
        let modern =
            environment["KITTY_WINDOW_ID"] != nil || environment["WEZTERM_EXECUTABLE"] != nil
            || ["ghostty", "iterm.app", "wezterm", "kitty"].contains(program)
        let knownTrueColor =
            modern || environment["WT_SESSION"] != nil
            || ["alacritty", "rio", "warpterminal", "vscode", "foot"].contains(program)
        let colorDepth: TerminalColorDepth
        if environment["NO_COLOR"] != nil || term == "dumb" || term.isEmpty {
            colorDepth = .monochrome
        } else if colorTerm == "truecolor" || colorTerm == "24bit" || knownTrueColor {
            colorDepth = .trueColor
        } else if term.contains("256color") {
            colorDepth = .ansi256
        } else {
            colorDepth = .ansi16
        }
        return Self(
            colorDepth: colorDepth,
            synchronizedOutput: modern && !multiplexed && term != "dumb",
            hyperlinks: modern && !multiplexed && term != "dumb",
            kittyKeyboard: (environment["KITTY_WINDOW_ID"] != nil || program == "ghostty") && !multiplexed
        )
    }

    /// A concise report suitable for terminal diagnostics.
    public var report: String {
        "COLOR       \(colorDepth.rawValue)\n"
            + "SYNC OUTPUT \(synchronizedOutput ? "on" : "off")\n"
            + "LINKS       \(hyperlinks ? "on" : "off")\n"
            + "KITTY KEYS  \(kittyKeyboard ? "available" : "unconfirmed")\n"
            + "Profile inferred from environment; tmux and SSH may hide terminal features."
    }
}
