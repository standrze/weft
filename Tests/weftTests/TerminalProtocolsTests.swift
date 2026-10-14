import Testing

@testable import weft

@Test func mouseButtonsModifiersAndFourWheelDirectionsSurviveEveryFragmentBoundary() {
    let position = Point(x: 2, y: 3)
    let cases: [(String, MouseEvent)] = [
        ("1;3;4M", MouseEvent(kind: .down, position: position, button: .middle)),
        ("30;3;4M", MouseEvent(kind: .down, position: position, button: .right, modifiers: [.shift, .alt, .control])),
        ("2;3;4m", MouseEvent(kind: .up, position: position, button: .right)),
        ("33;3;4M", MouseEvent(kind: .drag, position: position, button: .middle)),
        ("55;3;4M", MouseEvent(kind: .move, position: position, modifiers: [.shift, .control])),
        ("64;3;4M", MouseEvent(kind: .wheelUp, position: position)),
        ("65;3;4M", MouseEvent(kind: .wheelDown, position: position)),
        ("82;3;4M", MouseEvent(kind: .wheelLeft, position: position, modifiers: .control)),
        ("67;3;4M", MouseEvent(kind: .wheelRight, position: position)),
        ("128;3;4M", MouseEvent(kind: .down, position: position, button: .additional(8))),
        ("129;3;4m", MouseEvent(kind: .up, position: position, button: .additional(9))),
        ("162;3;4M", MouseEvent(kind: .drag, position: position, button: .additional(10))),
        ("131;3;4M", MouseEvent(kind: .down, position: position, button: .additional(11))),
    ]
    for (payload, expected) in cases {
        let wire = Array(("\u{1b}[<" + payload + "x").utf8)
        for split in 0...wire.count {
            var decoder = InputDecoder()
            #expect(
                decoder.feed(Array(wire.prefix(split))) + decoder.feed(Array(wire.dropFirst(split))) == [
                    .mouse(expected), .text("x"),
                ])
        }
    }
}

@Test func malformedMouseReportsDoNotShiftFieldsOrBecomeText() {
    for payload in [
        "1;;3;4M", "3;1;1M", "256;1;1M", "-1;1;1M", "+1;1;1M",
        "1;0;1M", "1;999999999999999999999999999999;1M", "64;1;1m", "192;1;1M",
    ] {
        var decoder = InputDecoder()
        #expect(decoder.feed(Array(("\u{1b}[<" + payload).utf8)).isEmpty)
        #expect(decoder.feed([120]) == [.text("x")])
    }
}

@Test func typedTerminalReportsRemainSeparateFromKeysAndLiteralPasteAcrossFragments() {
    let red = TerminalRGB(red: 65535, green: 0, blue: 0)
    let white = TerminalRGB(red: 65535, green: 65535, blue: 65535)
    let cases: [(String, TerminalReply)] = [
        ("\u{1b}[12;34R", .cursorPosition(Point(x: 33, y: 11))),
        ("\u{1b}[?31u", .kittyKeyboard(flags: 31)),
        ("\u{1b}[?0u", .kittyKeyboard(flags: 0)),
        ("\u{1b}]10;rgb:ff/00/00\u{7}", .foregroundColor(red)),
        ("\u{1b}]11;rgb:f/ffff/fff\u{1b}\\", .backgroundColor(white)),
        ("\u{1b}[?2031;2$y", .privateMode(2031, .reset)),
        ("\u{1b}[?2026;0$y", .privateMode(2026, .unrecognized)),
        ("\u{1b}[?997;1n", .colorScheme(.dark)),
        ("\u{1b}[?997;2n", .colorScheme(.light)),
        ("\u{1b}[?1;2c", .primaryDeviceAttributes([1, 2])),
    ]
    for (wire, reply) in cases {
        let bytes = Array((wire + "\u{1b}[200~" + wire + "\u{1b}[201~x").utf8)
        for split in 0...bytes.count {
            var decoder = InputDecoder(terminalReplies: true)
            #expect(
                decoder.feed(Array(bytes.prefix(split))) + decoder.feed(Array(bytes.dropFirst(split))) == [
                    .terminalReply(reply), .paste(wire), .text("x"),
                ])
        }
    }
}

@Test func replyParsingStaysBoundedAndUnknownOrInvalidResponsesStaySuppressed() {
    let invalid = [
        "\u{1b}[0;1R", "\u{1b}[+1;2R", "\u{1b}[?4294967296u", "\u{1b}[?0;2$y",
        "\u{1b}[?2026;9$y", "\u{1b}[?997;3n", "\u{1b}]10;rgb:gg/00/ff\u{7}",
        "\u{1b}]11;rgb:fffff/00/ff\u{7}", "\u{1b}]52;c;arbitrary\u{7}",
        "\u{1b}]10;rgb:" + String(repeating: "f", count: 10_000) + "\u{1b}\\",
        "\u{1b}[?" + String(repeating: "1;", count: 1000) + "c",
    ]
    for wire in invalid {
        var decoder = InputDecoder(terminalReplies: true)
        var events: [InputEvent] = []
        let bytes = Array(wire.utf8)
        for packet in stride(from: 0, to: bytes.count, by: 37) {
            events += decoder.feed(Array(bytes[packet..<min(packet + 37, bytes.count)]))
        }
        #expect(events.isEmpty)
        #expect(decoder.feed(Array("ok".utf8)) == [.text("o"), .text("k")])
    }
}

@Test func capabilityReportsOverrideOnlyConfirmedFeatures() {
    var profile = TerminalCapabilities()
    profile.apply(.kittyKeyboard(flags: 0))
    #expect(profile.kittyKeyboard)
    profile.apply(.kittyKeyboardUnsupported)
    #expect(!profile.kittyKeyboard)
    profile.apply(.privateMode(2026, .reset))
    profile.apply(.privateMode(2031, .set))
    #expect(profile.synchronizedOutput && profile.colorSchemeReporting)
    profile.apply(.privateMode(2026, .unrecognized))
    #expect(!profile.synchronizedOutput && profile.colorSchemeReporting)
    profile.apply(.privateMode(2031, .permanentlyReset))
    #expect(!profile.colorSchemeReporting)
}
