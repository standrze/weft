/// Input from the terminal or a change to the terminal session.
public enum InputEvent: Equatable, Sendable {
    case key(Key)
    case keyEvent(KeyEvent)
    case text(String)
    case paste(String)
    /// A bracketed paste exceeded the byte budget; only this prefix was retained.
    case pasteTruncated(String)
    case mouse(MouseEvent)
    /// A terminal focus report: true on focus gain, false on focus loss.
    case focusChanged(Bool)
    case resize(Int, Int)
    case signal(Int)
    /// A requested query completed through the same reader as keyboard input.
    case queryResult(TerminalQueryResult)
    /// A recognized report; sessions opt into unsolicited color-scheme updates.
    case terminalReply(TerminalReply)
    /// Terminal ownership was reacquired; applications should redraw their interface.
    case terminalResumed
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
