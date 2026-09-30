/// Estimates the number of terminal cells occupied by one character.
///
/// Terminals can disagree on ambiguous-width characters and emoji. A renderer
/// can substitute its own width policy when matching a particular terminal.
public func terminalCellWidth(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    let usesEmojiWidth = scalars.contains { scalar in
        scalar.value == 0xfe0f || scalar.value == 0x200d || (0x1f1e6...0x1f1ff).contains(scalar.value)
    }
    if usesEmojiWidth {
        return 2
    }

    var width = 0
    for scalar in scalars {
        let measured = Reed.width(scalar)
        if measured >= 0 {
            width += measured
        } else {
            let value = scalar.value
            let usesWideFallback =
                (0x1100...0x115f).contains(value)
                || (0x2e80...0xa4cf).contains(value)
                || (0xac00...0xd7a3).contains(value)
                || (0xf900...0xfaff).contains(value)
                || (0x1f300...0x1faff).contains(value)
                || (0x20000...0x3ffff).contains(value)
            width += usesWideFallback ? 2 : 1
        }
    }
    return min(2, max(0, width))
}
