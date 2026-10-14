/// Strict parsers for the bounded subset of terminal reports understood by weft.
internal enum TerminalReplyDecoder {
    static func controlSequence(_ code: String) -> TerminalReply? {
        if code.hasSuffix("R") {
            let fields = code.dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2, let row = decimal(fields[0]), row > 0,
                let column = decimal(fields[1]), column > 0
            else { return nil }
            return .cursorPosition(Point(x: column - 1, y: row - 1))
        }
        if code.hasPrefix("?"), code.hasSuffix("u"),
            let flags = decimal(code.dropFirst().dropLast()), let value = UInt32(exactly: flags)
        {
            return .kittyKeyboard(flags: value)
        }
        if code.hasPrefix("?997;"), code.hasSuffix("n"),
            let value = decimal(code.dropFirst(5).dropLast()), let scheme = TerminalColorScheme(rawValue: value)
        {
            return .colorScheme(scheme)
        }
        if code.hasPrefix("?"), code.hasSuffix("$y") {
            let fields = code.dropFirst().dropLast(2).split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2, let number = decimal(fields[0]), (1...65535).contains(number),
                let value = decimal(fields[1]), let state = TerminalModeState(rawValue: value)
            else { return nil }
            return .privateMode(number, state)
        }
        if code.hasPrefix("?"), code.hasSuffix("c") {
            let fields = code.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard !fields.isEmpty, fields.count <= 32 else { return nil }
            let values = fields.compactMap(decimal)
            guard values.count == fields.count else { return nil }
            return .primaryDeviceAttributes(values)
        }
        return nil
    }

    static func operatingSystemCommand(_ bytes: [UInt8]) -> TerminalReply? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "10" || fields[0] == "11", fields[1].hasPrefix("rgb:") else {
            return nil
        }
        let channels = fields[1].dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        guard channels.count == 3 else { return nil }
        let values = channels.compactMap { component -> UInt16? in
            guard (1...4).contains(component.count),
                component.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }), let value = UInt32(component, radix: 16)
            else { return nil }
            let maximum = (UInt32(1) << (component.count * 4)) - 1
            return UInt16((value * 65535 + maximum / 2) / maximum)
        }
        guard values.count == 3 else { return nil }
        let color = TerminalRGB(red: values[0], green: values[1], blue: values[2])
        return fields[0] == "10" ? .foregroundColor(color) : .backgroundColor(color)
    }

    private static func decimal(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }
}
