/// A mouse action reported by the terminal.
public enum MouseKind: Equatable, Sendable {
    /// Pointer motion without a pressed button, when explicitly enabled.
    case move
    case down
    case drag
    case up
    case wheelUp
    case wheelDown
}

/// A mouse action and its zero-based terminal position.
public struct MouseEvent: Equatable, Sendable {
    public let kind: MouseKind
    public let position: Point

    public init(kind: MouseKind, position: Point) {
        self.kind = kind
        self.position = position
    }
}
