/// Estimates the terminal cells occupied by one extended grapheme cluster.
///
/// This locale-independent policy treats combining marks, controls and default-ignorable
/// scalars as zero cells, ambiguous-width characters as narrow, and East Asian wide/fullwidth
/// characters as two cells. Emoji presentation sequences occupy two cells. VS15 requests
/// text presentation but does not narrow an inherently East Asian wide character.
/// Terminals may differ; renderers can substitute a width policy for a particular terminal.
public func terminalCellWidth(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    let textPresentation = scalars.contains { $0.value == 0xfe0e }
    let emojiPresentation = scalars.contains { $0.value == 0xfe0f }
    let hasEmojiBase = scalars.contains { $0.properties.isEmoji && !isZeroWidth($0) }
    let keycap = scalars.contains { $0.value == 0x20e3 }
    if !textPresentation && hasEmojiBase && (emojiPresentation || keycap) { return 2 }

    var width = 0
    for scalar in scalars where !isZeroWidth(scalar) {
        if !textPresentation && scalar.properties.isEmojiPresentation { return 2 }
        width += UnicodeWidthData.isWide(scalar.value) ? 2 : 1
        if width >= 2 { return 2 }
    }
    return width
}

private func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isDefaultIgnorableCodePoint { return true }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark, .control, .format, .lineSeparator, .paragraphSeparator:
        return true
    default:
        return false
    }
}
