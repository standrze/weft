import Foundation
import Testing

@testable import weft

@Test func inputPreservesFragmentedUnicodeEscapeAndPaste() {
    var decoder = InputDecoder()
    #expect(decoder.feed([27, 91, 60, 48, 59]).isEmpty)
    #expect(decoder.feed(Array("3;4M".utf8)) == [.mouse(MouseEvent(kind: .down, position: Point(x: 2, y: 3)))])
    let bytes = Array("中".utf8)
    #expect(decoder.feed(Array(bytes.prefix(2))).isEmpty)
    #expect(decoder.feed([bytes.last!]) == [.text("中")])
    #expect(decoder.feed(Array("\u{1b}[200~line\n\u{3}".utf8)).isEmpty)
    #expect(decoder.feed(Array("\u{1b}[201".utf8)).isEmpty)
    #expect(decoder.feed([126]) == [.paste("line\n\u{3}")])
    #expect(decoder.feed([27]).isEmpty)
    #expect(decoder.flushEscape() == [.key(.escape)])
    #expect(decoder.feed(Array("\u{1b}[?9999h".utf8)).isEmpty)
}

@Test func largePasteIsOneLiteralEventAndDoesNotSwallowFollowingKey() {
    var decoder = InputDecoder()
    let text = String(repeating: "中\n", count: 20_000)
    let bytes = Array(("\u{1b}[200~" + text + "\u{1b}[201~\r").utf8)
    var events: [InputEvent] = []
    for start in stride(from: 0, to: bytes.count, by: 997) {
        events += decoder.feed(Array(bytes[start..<min(start + 997, bytes.count)]))
    }
    #expect(events == [.paste(text), .key(.enter)])
}

@Test func modifiedKeysPreserveModifiersAndEventKinds() {
    var decoder = InputDecoder()
    #expect(
        decoder.feed(Array("\u{1b}[1;5A".utf8)) == [
            .keyEvent(KeyEvent(key: .up, modifiers: .control))
        ])
    #expect(
        decoder.feed(Array("\u{1b}[1;5F\u{1b}[Z".utf8)) == [
            .keyEvent(KeyEvent(key: .end, modifiers: .control)),
            .keyEvent(KeyEvent(key: .tab, modifiers: .shift)),
        ])
    #expect(
        decoder.feed(Array("\u{1b}[13;2:2u\u{1b}[13;2:3u".utf8)) == [
            .keyEvent(KeyEvent(key: .enter, modifiers: .shift, kind: .repeated)),
            .keyEvent(KeyEvent(key: .enter, modifiers: .shift, kind: .release)),
        ])
    #expect(
        decoder.feed(Array("\u{1b}[97u\u{1b}[97;2u".utf8)) == [
            .text("a"),
            .keyEvent(KeyEvent(key: .character("a"), modifiers: .shift)),
        ])
}

@Test func altAndFunctionKeysDecodeAcrossReadBoundaries() {
    var decoder = InputDecoder()
    #expect(decoder.feed([27]).isEmpty)
    #expect(
        decoder.feed(Array("x".utf8)) == [
            .keyEvent(KeyEvent(key: .character("x"), modifiers: .alt))
        ])
    #expect(
        decoder.feed(Array("\u{1b}OQ\u{1b}OP\u{1b}[15~\t".utf8)) == [
            .key(.f2), .key(.function(1)), .key(.function(5)), .key(.tab),
        ])
    #expect(
        decoder.feed(Array("\u{1b}[3;2~".utf8)) == [
            .keyEvent(KeyEvent(key: .delete, modifiers: .shift))
        ])
}

@Test func associatedTextAndLegacyKeysHaveAUniformKeyboardView() {
    var decoder = InputDecoder()
    let shifted = decoder.feed(Array("\u{1b}[97;2;65u".utf8))
    #expect(
        shifted == [
            .keyEvent(KeyEvent(key: .character("a"), modifiers: .shift, text: "A"))
        ])
    #expect(shifted[0].keyboardEvent?.text == "A")
    #expect(InputEvent.key(.enter).keyboardEvent == KeyEvent(key: .enter))
    #expect(InputEvent.text("x").keyboardEvent == KeyEvent(key: .character("x"), text: "x"))
    #expect(InputEvent.paste("multiple").keyboardEvent == nil)
    #expect(
        decoder.feed(Array("\u{1b}\r".utf8)) == [
            .keyEvent(KeyEvent(key: .enter, modifiers: .alt))
        ])
}

@Test func legacyControlKeysPreserveShortcutsWithoutDroppingOtherLetters() {
    var decoder = InputDecoder()
    #expect(
        decoder.feed([1, 5, 26, 0, 28, 29, 30, 31]) == [
            .keyEvent(KeyEvent(key: .character("a"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("e"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("z"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character(" "), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("\\"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("]"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("^"), modifiers: .control)),
            .keyEvent(KeyEvent(key: .character("_"), modifiers: .control)),
        ])
    #expect(
        decoder.feed([3, 4, 8, 9, 10, 13, 127]) == [
            .key(.interrupt), .key(.endOfInput), .key(.backspace), .key(.tab),
            .key(.newline), .key(.enter), .key(.backspace),
        ])
    #expect(decoder.feed([27, 1]) == [.keyEvent(KeyEvent(key: .character("a"), modifiers: [.control, .alt]))])
}

@Test func alternateLayoutKeysAndProducedTextRemainDistinct() {
    var decoder = InputDecoder()
    #expect(
        decoder.feed(Array("\u{1b}[97:65:113;6:2;65u".utf8)) == [
            .keyEvent(
                KeyEvent(
                    key: .character("a"), modifiers: [.shift, .control], kind: .repeated, text: "A",
                    shiftedKey: .character("A"), baseLayoutKey: .character("q")
                ))
        ])
    #expect(
        decoder.feed(Array("\u{1b}[1089::99;5u".utf8)) == [
            .keyEvent(KeyEvent(key: .character("с"), modifiers: .control, baseLayoutKey: .character("c")))
        ])
    #expect(decoder.feed(Array("\u{1b}[0;;229u".utf8)) == [.text("å")])
    #expect(
        decoder.feed(Array("\u{1b}[0;1:2;101:769u".utf8)) == [
            .keyEvent(KeyEvent(key: .unknown, kind: .repeated, text: "e\u{301}"))
        ])
}

@Test func functionalKeyPhasesAndAllModifierBitsArePreserved() {
    var decoder = InputDecoder()
    #expect(
        decoder.feed(Array("\u{1b}[1;5:2A\u{1b}[13;2:3~\u{1b}[1;3P".utf8)) == [
            .keyEvent(KeyEvent(key: .up, modifiers: .control, kind: .repeated)),
            .keyEvent(KeyEvent(key: .function(3), modifiers: .shift, kind: .release)),
            .keyEvent(KeyEvent(key: .function(1), modifiers: .alt)),
        ])
    #expect(
        decoder.feed(Array("\u{1b}[97;241u".utf8)) == [
            .keyEvent(KeyEvent(key: .character("a"), modifiers: [.hyper, .meta, .capsLock, .numLock]))
        ])
    #expect(
        decoder.feed(Array("\u{1b}OA\u{1b}OB\u{1b}OC\u{1b}OD".utf8)) == [
            .key(.up), .key(.down), .key(.right), .key(.left),
        ])
}

@Test func terminalRepliesNeverBecomeTypedTextAcrossReadBoundaries() {
    let replies = [
        "\u{1b}[?31u", "\u{1b}[?1;2c", "\u{1b}[>0;95;0c", "\u{1b}[1;5R",
        "\u{1b}]10;rgb:ffff/ffff/ffff\u{7}",
        "\u{1b}P1+r544e=787465726d\u{1b}\\",
        "\u{1b}_ignored\u{1b}\\", "\u{1b}^ignored\u{1b}\\", "\u{1b}Xignored\u{1b}\\",
    ]
    for reply in replies {
        let bytes = Array((reply + "ok\r").utf8)
        for split in 1..<bytes.count {
            var decoder = InputDecoder()
            var events = decoder.feed(Array(bytes.prefix(split)))
            events += decoder.feed(Array(bytes.dropFirst(split)))
            #expect(events == [.text("o"), .text("k"), .key(.enter)])
        }
    }
}

@Test func invalidExtendedKeyFieldsDoNotBecomeTextOrPartialEvents() {
    var decoder = InputDecoder()
    let sequences = [
        "\u{1b}[97;0u", "\u{1b}[97;257u", "\u{1b}[97;1:9u",
        "\u{1b}[97;1;65:7:66u", "\u{1b}[97;1;55296u",
        "\u{1b}[55296u", "\u{1b}[0u", "\u{1b}[57441u",
    ]
    for sequence in sequences {
        #expect(decoder.feed(Array(sequence.utf8)).isEmpty)
    }
    #expect(decoder.feed(Array("\u{1b}[97:55296;1u".utf8)).isEmpty)
    #expect(decoder.feed(Array("next".utf8)) == [.text("n"), .text("e"), .text("x"), .text("t")])
}

@Test func extendedInputAndLiteralPasteSurviveByteByByteDelivery() {
    var decoder = InputDecoder()
    let source = "\u{1b}[97:65;2:3u\u{1b}[200~\u{1b}]literal\u{7}\u{1b}[201~"
    var events: [InputEvent] = []
    for byte in source.utf8 {
        events += decoder.feed([byte])
    }
    #expect(
        events == [
            .keyEvent(KeyEvent(key: .character("a"), modifiers: .shift, kind: .release, shiftedKey: .character("A"))),
            .paste("\u{1b}]literal\u{7}"),
        ])
    #expect(!decoder.hasPendingEscape)
    #expect(decoder.feed([27]).isEmpty)
    #expect(decoder.hasPendingEscape)
    #expect(decoder.flushEscape() == [.key(.escape)])
    #expect(!decoder.hasPendingEscape)
}

@Test func pointerMotionIsDistinctFromButtonDragging() {
    var decoder = InputDecoder()
    #expect(decoder.feed(Array("\u{1b}[<35;".utf8)).isEmpty)
    #expect(decoder.feed(Array("3;4M".utf8)) == [.mouse(MouseEvent(kind: .move, position: Point(x: 2, y: 3)))])
    #expect(
        decoder.feed(Array("\u{1b}[<32;3;4M".utf8)) == [.mouse(MouseEvent(kind: .drag, position: Point(x: 2, y: 3)))])
    #expect(decoder.feed(Array("\u{1b}[<0;3;4m".utf8)) == [.mouse(MouseEvent(kind: .up, position: Point(x: 2, y: 3)))])
}
