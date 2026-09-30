/// Input from the terminal or a change to the terminal session.
public enum InputEvent: Equatable, Sendable {
    case key(Key)
    case keyEvent(KeyEvent)
    case text(String)
    case paste(String)
    case mouse(MouseEvent)
    case resize(Int, Int)
    case signal(Int)
}

public extension InputEvent {
    /// A uniform keyboard view of legacy and extended input events.
    var keyboardEvent: KeyEvent? {
        switch self {
        case let .key(key):
            return KeyEvent(key: key)
        case let .keyEvent(event):
            return event
        case let .text(value) where value.count == 1:
            return KeyEvent(key: .character(value), text: value)
        default:
            return nil
        }
    }
}
