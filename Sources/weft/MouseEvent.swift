/// A mouse action reported by the terminal.
public enum MouseKind: Equatable, Sendable {
    /// Pointer motion without a pressed button, when explicitly enabled.
    case move
    case down
    case drag
    case up
    case wheelUp
    case wheelDown
    case wheelLeft
    case wheelRight
}

/// A mouse button identified by SGR terminal reports.
public enum MouseButton: Equatable, Sendable {
    case left
    case middle
    case right
    /// The xterm button number, from 8 through 11.
    case additional(Int)
}

/// A mouse action and its zero-based terminal position.
public struct MouseEvent: Equatable, Sendable {
    public let kind: MouseKind
    public let position: Point
    /// Nil for hover and scrolling.
    public let button: MouseButton?
    /// Shift, Alt, and Control, when reported by the terminal.
    public let modifiers: KeyModifiers

    public init(kind: MouseKind, position: Point, button: MouseButton? = nil, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.position = position
        // Preserve the conventional left-button meaning of existing initializers.
        switch kind {
        case .down, .drag, .up: self.button = button ?? .left
        default: self.button = button
        }
        self.modifiers = modifiers
    }
}
