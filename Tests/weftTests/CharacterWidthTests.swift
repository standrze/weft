import Testing

@testable import weft

// Every case runs in separate C and C.UTF-8 CI processes; none changes the process locale.
@Test func characterWidthCombiningAndIgnorableScalarsDoNotAddCells() {
    for text in ["e\u{301}", "a\u{308}\u{301}", "e\u{200d}", "क\u{93e}"] {
        #expect(text.count == 1)
        #expect(terminalCellWidth(Character(text)) == 1)
    }
    for text in ["\u{301}", "\u{fe0f}", "\u{200d}", "\u{200b}", "\u{ad}", "\u{2060}", "\u{e0100}"] {
        #expect(terminalCellWidth(Character(text)) == 0)
    }
    #expect(terminalCellWidth("\u{0}") == 0)
    #expect(terminalCellWidth("\t") == 0)
}

@Test func characterWidthUsesWideAndNarrowUnicodeProperties() {
    for character: Character in ["界", "あ", "한", "가", "Ａ", "\u{20000}", "\u{30000}", "\u{2329}", "\u{4dc0}"] {
        #expect(terminalCellWidth(character) == 2)
    }
    for character: Character in ["A", "é", "α", "·", "─", "ｶ", "\u{303f}"] {
        #expect(terminalCellWidth(character) == 1)
    }
    #expect(terminalCellWidth("界\u{301}") == 2)
}

@Test func characterWidthDistinguishesEmojiAndTextPresentation() {
    for character: Character in ["😀", "👨‍👩‍👧‍👦", "👍🏽", "🇵🇱", "❤️", "1️⃣", "1\u{20e3}"] {
        #expect(terminalCellWidth(character) == 2)
    }
    #expect(terminalCellWidth("❤") == 1)
    #expect(terminalCellWidth("❤\u{fe0e}") == 1)
    #expect(terminalCellWidth("©\u{fe0f}") == 2)
    #expect(terminalCellWidth("©\u{fe0e}") == 1)
    #expect(terminalCellWidth("e\u{fe0f}") == 1)
    #expect(terminalCellWidth("😀\u{fe0e}") == 2)
}
