import Testing

@testable import weft

@Test func inferredCapabilitiesStayConservativeInUnknownAndMultiplexedTerminals() {
    let unknown = TerminalCapabilities.inferred(environment: ["TERM": "xterm-256color"])
    #expect(unknown.colorDepth == .ansi256)
    #expect(!unknown.synchronizedOutput && !unknown.hyperlinks && !unknown.kittyKeyboard)

    let ghostty = TerminalCapabilities.inferred(environment: ["TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty"])
    #expect(ghostty.colorDepth == .trueColor)
    #expect(ghostty.synchronizedOutput && ghostty.hyperlinks && ghostty.kittyKeyboard)

    let tmux = TerminalCapabilities.inferred(environment: [
        "TERM": "screen-256color", "TERM_PROGRAM": "ghostty", "TMUX": "fixture",
    ])
    #expect(tmux.colorDepth == .trueColor)
    #expect(!tmux.synchronizedOutput && !tmux.hyperlinks && !tmux.kittyKeyboard)

    let unknownTmux = TerminalCapabilities.inferred(environment: ["TERM": "screen-256color", "TMUX": "fixture"])
    #expect(unknownTmux.colorDepth == .ansi256)

    let editorTmux = TerminalCapabilities.inferred(environment: [
        "TERM": "screen-256color", "TERM_PROGRAM": "vscode", "TMUX": "fixture",
    ])
    #expect(editorTmux.colorDepth == .trueColor)
    #expect(!editorTmux.synchronizedOutput && !editorTmux.hyperlinks)

    let noColor = TerminalCapabilities.inferred(environment: ["TERM": "xterm-256color", "NO_COLOR": "1"])
    #expect(noColor.colorDepth == .monochrome)
}
