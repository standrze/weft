import Foundation

/// Decodes terminal input incrementally across arbitrary read boundaries.
///
/// Escape sequences, UTF-8 characters, and bracketed pastes can each span
/// multiple calls to `feed(_:)`.
public struct InputDecoder {
    private var pendingBytes: [UInt8] = []
    private var pasteBytes: [UInt8]?
    private let pasteLimit: Int
    private var pasteWasTruncated = false
    private var controlString: DiscardedControlString?
    private let terminalReplies: Bool
    private var discardingCSI = false

    private struct DiscardedControlString {
        var acceptsBell: Bool
        var previousWasEscape = false
        var bytes: [UInt8] = []
        var oversized = false
    }

    /// Bounds retained UTF-8 paste bytes; bytes beyond the limit are consumed until the terminator.
    ///
    /// The default retains at most 1 MiB. Protocol-aware callers may choose a larger finite budget.
    /// Oversized pastes produce `.pasteTruncated` with a prefix ending at a complete UTF-8 scalar.
    /// Opt into recognized typed reports without turning unknown replies into text.
    public init(maximumPasteBytes: Int = 1_048_576, terminalReplies: Bool = false) {
        pasteLimit = max(0, maximumPasteBytes)
        self.terminalReplies = terminalReplies
    }

    internal var hasPendingEscape: Bool {
        pasteBytes == nil && controlString == nil && !discardingCSI && pendingBytes == [27]
    }

    /// Treats a lone escape byte as a key after the caller's input timeout.
    public mutating func flushEscape() -> [InputEvent] {
        guard hasPendingEscape else {
            return []
        }
        pendingBytes = []
        return [.key(.escape)]
    }

    /// Decodes all complete input and retains any incomplete trailing sequence.
    public mutating func feed(_ bytes: [UInt8]) -> [InputEvent] {
        pendingBytes += bytes
        var events: [InputEvent] = []
        var cursor = 0

        // Consume with an index, then compact once. Large pastes stay linear.
        while cursor < pendingBytes.count {
            let remainingCount = pendingBytes.count - cursor
            if discardingCSI {
                if (0x40...0x7e).contains(pendingBytes[cursor]) { discardingCSI = false }
                cursor += 1
                continue
            }

            // Terminal replies are not keystrokes. Discard control-string payloads
            // incrementally so a fragmented or long response cannot become text.
            if var reply = controlString {
                let byte = pendingBytes[cursor]
                if (reply.acceptsBell && byte == 7) || (reply.previousWasEscape && byte == 92) {
                    if reply.previousWasEscape && byte == 92 && reply.bytes.last == 27 { reply.bytes.removeLast() }
                    if terminalReplies, reply.acceptsBell, !reply.oversized,
                        let report = TerminalReplyDecoder.operatingSystemCommand(reply.bytes)
                    {
                        events.append(.terminalReply(report))
                    }
                    controlString = nil
                } else {
                    if reply.acceptsBell && terminalReplies {
                        if reply.bytes.count < 256 { reply.bytes.append(byte) } else { reply.oversized = true }
                    }
                    reply.previousWasEscape = byte == 27
                    controlString = reply
                }
                cursor += 1
                continue
            }

            if pasteBytes != nil {
                let pasteTerminator: [UInt8] = [27, 91, 50, 48, 49, 126]
                if pendingBytes[cursor...].starts(with: pasteTerminator) {
                    var retained = pasteBytes!
                    if pasteWasTruncated {
                        // A byte budget may split the final UTF-8 scalar. Remove that
                        // incomplete suffix rather than inventing a replacement character.
                        if let start = retained.lastIndex(where: { $0 & 0xc0 != 0x80 }),
                            utf8SequenceLength(startingWith: retained[start]) > retained.count - start
                        {
                            retained.removeSubrange(start...)
                        }
                    }
                    let text = String(decoding: retained, as: UTF8.self)
                    events.append(pasteWasTruncated ? .pasteTruncated(text) : .paste(text))
                    pasteBytes = nil
                    pasteWasTruncated = false
                    cursor += pasteTerminator.count
                    continue
                }
                if remainingCount < pasteTerminator.count,
                    pasteTerminator.starts(with: pendingBytes[cursor...])
                {
                    break
                }
                if pasteBytes!.count < pasteLimit {
                    pasteBytes!.append(pendingBytes[cursor])
                } else {
                    pasteWasTruncated = true
                }
                cursor += 1
                continue
            }

            let byte = pendingBytes[cursor]
            if byte == 27 {
                guard remainingCount >= 2 else {
                    break
                }

                // OSC, DCS, SOS, PM, and APC responses end with ST; OSC also
                // accepts BEL. Bracketed paste was handled above and stays literal.
                let introducer = pendingBytes[cursor + 1]
                if [93, 80, 88, 94, 95].contains(introducer) {
                    controlString = DiscardedControlString(acceptsBell: introducer == 93)
                    cursor += 2
                    continue
                }

                // CSI sequences begin with ESC [ and end with a final byte.
                if pendingBytes[cursor + 1] == 91 {
                    let sequenceRange = cursor + 2..<pendingBytes.count
                    guard let end = sequenceRange.first(where: { (0x40...0x7e).contains(pendingBytes[$0]) }) else {
                        if remainingCount > 128 {
                            discardingCSI = true
                            cursor = pendingBytes.count
                        }
                        break
                    }
                    guard end - cursor <= 128 else {
                        cursor = end + 1
                        continue
                    }
                    let code = String(decoding: pendingBytes[cursor + 2...end], as: UTF8.self)
                    cursor = end + 1

                    if code == "200~" {
                        pasteBytes = []
                        pasteWasTruncated = false
                        continue
                    }
                    if let event = decodeControlSequence(code) {
                        events.append(event)
                    }
                    continue
                }

                // SS3 sequences begin with ESC O and contain one key byte.
                if pendingBytes[cursor + 1] == 79 {
                    guard remainingCount >= 3 else {
                        break
                    }
                    let code = pendingBytes[cursor + 2]
                    cursor += 3

                    let keys: [UInt8: Key] = [
                        80: .function(1), 81: .f2, 82: .function(3), 83: .function(4),
                        72: .home, 70: .end,
                        65: .up, 66: .down, 67: .right, 68: .left,
                        69: .begin, 77: .enter,
                        106: .character("*"), 107: .character("+"), 108: .character(","),
                        109: .character("-"), 110: .character("."), 111: .character("/"),
                        88: .character("="),
                    ]
                    let key =
                        (112...121).contains(code)
                        ? Key.character(String(code - 112)) : keys[code]
                    if let key {
                        if case let .character(text) = key {
                            events.append(.text(text))
                        } else {
                            events.append(.key(key))
                        }
                    }
                    continue
                }

                // An escape prefix followed by a control key is Alt+key.
                let next = pendingBytes[cursor + 1]
                let altControls: [UInt8: Key] = [
                    9: .tab, 10: .newline, 13: .enter, 8: .backspace, 127: .backspace,
                ]
                if let key = altControls[next] {
                    events.append(.keyEvent(KeyEvent(key: key, modifiers: .alt)))
                    cursor += 2
                    continue
                }

                if let key = legacyControlCharacter(next) {
                    events.append(.keyEvent(KeyEvent(key: key, modifiers: [.alt, .control])))
                    cursor += 2
                    continue
                }

                // An escape prefix followed by a printable character is Alt+key.
                let characterLength = utf8SequenceLength(startingWith: next)
                guard remainingCount >= characterLength + 1 else {
                    break
                }
                let characterBytes = pendingBytes[cursor + 1..<cursor + 1 + characterLength]
                if let value = String(bytes: characterBytes, encoding: .utf8),
                    value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
                {
                    events.append(.keyEvent(KeyEvent(key: .character(value), modifiers: .alt)))
                    cursor += characterLength + 1
                    continue
                }
                cursor += 1
                events.append(.key(.escape))
                continue
            }

            let controlKeys: [UInt8: Key] = [
                3: .interrupt,
                4: .endOfInput,
                10: .newline,
                13: .enter,
                9: .tab,
                8: .backspace,
                127: .backspace,
            ]
            if let key = controlKeys[byte] {
                cursor += 1
                events.append(.key(key))
                continue
            }
            if let key = legacyControlCharacter(byte) {
                events.append(.keyEvent(KeyEvent(key: key, modifiers: .control)))
                cursor += 1
                continue
            }

            let characterLength = utf8SequenceLength(startingWith: byte)
            guard remainingCount >= characterLength else {
                break
            }

            let characterBytes = pendingBytes[cursor..<cursor + characterLength]
            if let text = String(bytes: characterBytes, encoding: .utf8) {
                events.append(.text(text))
                cursor += characterLength
            } else {
                events.append(.text("�"))
                cursor += 1
            }
        }

        pendingBytes.removeFirst(cursor)
        return events
    }

    private func legacyControlCharacter(_ byte: UInt8) -> Key? {
        switch byte {
        case 0:
            return .character(" ")
        case 1...26:
            return .character(String(UnicodeScalar(UInt32(byte) + 96)!))
        case 28...31:
            return .character(String(UnicodeScalar(UInt32(byte) + 64)!))
        default:
            return nil
        }
    }

    private func utf8SequenceLength(startingWith byte: UInt8) -> Int {
        switch byte {
        case 0..<0x80:
            return 1
        case 0xc2...0xdf:
            return 2
        case 0xe0...0xef:
            return 3
        case 0xf0...0xf4:
            return 4
        default:
            return 1
        }
    }

    private func decodeControlSequence(_ code: String) -> InputEvent? {
        if terminalReplies, let report = TerminalReplyDecoder.controlSequence(code) {
            return .terminalReply(report)
        }
        if code == "I" { return .focusChanged(true) }
        if code == "O" { return .focusChanged(false) }
        let plainKeys: [String: Key] = [
            "A": .up, "B": .down, "C": .right, "D": .left,
            "H": .home, "F": .end, "1~": .home, "4~": .end,
            "3~": .delete, "5~": .pageUp, "6~": .pageDown,
            "12~": .f2, "P": .function(1), "Q": .f2, "S": .function(4),
            "E": .begin, "1E": .begin,
        ]
        if let key = plainKeys[code] {
            return .key(key)
        }
        if code == "Z" {
            return .keyEvent(KeyEvent(key: .tab, modifiers: .shift))
        }
        if let event = decodeExtendedKey(code) {
            return event
        }
        return decodeMouse(code)
    }

    private func decodeExtendedKey(_ code: String) -> InputEvent? {
        guard let suffix = code.last else {
            return nil
        }
        let parameters = code.dropLast().split(separator: ";", omittingEmptySubsequences: false)
        if suffix == "u" {
            return decodeUnicodeKey(parameters)
        }

        if suffix == "~", parameters.count == 1,
            let number = Int(parameters[0]), let key = tildeKey(number)
        {
            return .key(key)
        }

        guard parameters.count == 2, parameters[0] == "1" || suffix == "~",
            let (modifiers, kind) = decodeModifierAndKind(parameters[1])
        else {
            return nil
        }
        let key: Key
        switch suffix {
        case "A": key = .up
        case "B": key = .down
        case "C": key = .right
        case "D": key = .left
        case "E": key = .begin
        case "H": key = .home
        case "F": key = .end
        case "P": key = .function(1)
        case "Q": key = .f2
        case "S": key = .function(4)
        case "~":
            guard let number = Int(parameters[0]), let special = tildeKey(number) else {
                return nil
            }
            key = special
        default:
            // CSI R is a cursor-position response, not F3. F3 uses SS3 R or 13~.
            return nil
        }
        return .keyEvent(KeyEvent(key: key, modifiers: modifiers, kind: kind))
    }

    private func decodeUnicodeKey(_ parameters: [Substring]) -> InputEvent? {
        guard (1...3).contains(parameters.count) else {
            return nil
        }
        let codes = parameters[0].split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(codes.count), let scalarValue = UInt32(codes[0]),
            let key = unicodeKey(scalarValue),
            let (modifiers, kind) = decodeModifierAndKind(parameters.count > 1 ? parameters[1] : "")
        else {
            return nil
        }
        var alternateKeys: [Key?] = []
        for code in codes.dropFirst() {
            if code.isEmpty {
                alternateKeys.append(nil)
            } else if let value = UInt32(code), let alternate = unicodeKey(value), alternate != .unknown {
                alternateKeys.append(alternate)
            } else {
                return nil
            }
        }
        let shiftedKey = alternateKeys.first ?? nil
        let baseLayoutKey = alternateKeys.count > 1 ? alternateKeys[1] : nil
        let associatedText = parameters.count > 2 ? decodedAssociatedText(parameters[2]) : nil
        if parameters.count > 2, associatedText == nil {
            return nil
        }
        guard key != .unknown || associatedText != nil else {
            return nil
        }
        if modifiers.isEmpty, kind == .press, alternateKeys.isEmpty {
            if key == .unknown, let associatedText {
                return .text(associatedText)
            }
            if case let .character(text) = key {
                return .text(associatedText ?? text)
            }
        }
        return .keyEvent(
            KeyEvent(
                key: key, modifiers: modifiers, kind: kind, text: associatedText,
                shiftedKey: shiftedKey, baseLayoutKey: baseLayoutKey
            )
        )
    }

    private func unicodeKey(_ value: UInt32) -> Key? {
        switch value {
        case 0: return .unknown
        case 8, 127: return .backspace
        case 9: return .tab
        case 10: return .newline
        case 13: return .enter
        case 27: return .escape
        case 57376...57398: return .function(Int(value - 57376 + 13))
        case 57399...57408: return .character(String(value - 57399))
        case 57409: return .character(".")
        case 57410: return .character("/")
        case 57411: return .character("*")
        case 57412: return .character("-")
        case 57413: return .character("+")
        case 57414: return .enter
        case 57415: return .character("=")
        case 57416: return .character(",")
        case 57417: return .left
        case 57418: return .right
        case 57419: return .up
        case 57420: return .down
        case 57421: return .pageUp
        case 57422: return .pageDown
        case 57423: return .home
        case 57424: return .end
        case 57425: return .insert
        case 57426: return .delete
        case 57427: return .begin
        default:
            // Other private-use functional keys (media and modifier keys)
            // are outside the current key vocabulary; never insert their glyphs.
            guard value >= 32, !(0x7f...0x9f).contains(value), !(57344...63743).contains(value),
                let scalar = UnicodeScalar(value)
            else {
                return nil
            }
            return .character(String(scalar))
        }
    }

    private func decodeModifierAndKind(_ parameter: Substring) -> (KeyModifiers, KeyEventKind)? {
        let values = parameter.split(separator: ":", omittingEmptySubsequences: false)
        guard values.count <= 2 else {
            return nil
        }
        let modifierField = values.first ?? ""
        guard let encoded = modifierField.isEmpty ? 1 : Int(modifierField), (1...256).contains(encoded) else {
            return nil
        }
        let kindField = values.count > 1 ? values[1] : ""
        guard let kindCode = kindField.isEmpty ? 1 : Int(kindField) else {
            return nil
        }
        let kind: KeyEventKind
        switch kindCode {
        case 1: kind = .press
        case 2: kind = .repeated
        case 3: kind = .release
        default: return nil
        }
        return (KeyModifiers(rawValue: UInt8(encoded - 1)), kind)
    }

    private func decodedAssociatedText(_ parameter: Substring) -> String? {
        var result = ""
        for code in parameter.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = UInt32(code), value >= 32, !(0x7f...0x9f).contains(value),
                let scalar = UnicodeScalar(value)
            else {
                return nil
            }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? nil : result
    }

    private func tildeKey(_ number: Int) -> Key? {
        switch number {
        case 1, 7: .home
        case 2: .insert
        case 3: .delete
        case 4, 8: .end
        case 5: .pageUp
        case 6: .pageDown
        case 11: .function(1)
        case 12: .f2
        case 13: .function(3)
        case 14: .function(4)
        case 15: .function(5)
        case 17: .function(6)
        case 18: .function(7)
        case 19: .function(8)
        case 20: .function(9)
        case 21: .function(10)
        case 23: .function(11)
        case 24: .function(12)
        case 57427: .begin
        default: nil
        }
    }

    private func decodeMouse(_ code: String) -> InputEvent? {
        guard code.first == "<", code.last == "M" || code.last == "m" else {
            return nil
        }
        let fields = code.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
            let encoded = Int(fields[0]), (0...255).contains(encoded),
            let x = Int(fields[1]), x > 0, let y = Int(fields[2]), y > 0
        else {
            return nil
        }
        var modifiers: KeyModifiers = []
        if encoded & 4 != 0 { modifiers.insert(.shift) }
        if encoded & 8 != 0 { modifiers.insert(.alt) }
        if encoded & 16 != 0 { modifiers.insert(.control) }
        let kind: MouseKind
        var button: MouseButton?
        if encoded & 64 != 0 {
            guard encoded & (128 | 32) == 0, code.last == "M" else { return nil }
            switch encoded & 3 {
            case 0: kind = .wheelUp
            case 1: kind = .wheelDown
            case 2: kind = .wheelLeft
            default: kind = .wheelRight
            }
        } else if encoded & 128 != 0 {
            button = .additional(8 + (encoded & 3))
            kind = code.last == "m" ? .up : encoded & 32 != 0 ? .drag : .down
        } else if encoded & 32 != 0 && encoded & 3 == 3 && code.last == "M" {
            kind = .move
        } else {
            switch encoded & 3 {
            case 0: button = .left
            case 1: button = .middle
            case 2: button = .right
            default: return nil
            }
            kind = code.last == "m" ? .up : encoded & 32 != 0 ? .drag : .down
        }
        return .mouse(MouseEvent(kind: kind, position: Point(x: x - 1, y: y - 1), button: button, modifiers: modifiers))
    }
}
