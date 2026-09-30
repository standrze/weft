/// Modifier bits reported by supported terminal keyboard protocols.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let superKey = KeyModifiers(rawValue: 1 << 3)
    public static let hyper = KeyModifiers(rawValue: 1 << 4)
    public static let meta = KeyModifiers(rawValue: 1 << 5)
    public static let capsLock = KeyModifiers(rawValue: 1 << 6)
    public static let numLock = KeyModifiers(rawValue: 1 << 7)
}

/// Whether the key was pressed, repeated, or released.
public enum KeyEventKind: Equatable, Sendable {
    case press
    case repeated
    case release
}

/// A key with modifiers and an optional repeat/release phase.
public struct KeyEvent: Equatable, Sendable {
    public let key: Key
    public let modifiers: KeyModifiers
    public let kind: KeyEventKind
    /// Text produced by the key, when supplied by the terminal.
    public let text: String?
    /// The shifted key in the current keyboard layout, when reported.
    public let shiftedKey: Key?
    /// The physical key in the standard layout, useful for matching shortcuts.
    public let baseLayoutKey: Key?

    public init(
        key: Key, modifiers: KeyModifiers = [], kind: KeyEventKind = .press, text: String? = nil,
        shiftedKey: Key? = nil, baseLayoutKey: Key? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.kind = kind
        self.text = text
        self.shiftedKey = shiftedKey
        self.baseLayoutKey = baseLayoutKey
    }
}
