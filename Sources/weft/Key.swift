/// A key identity understood by the input decoder.
public enum Key: Equatable, Sendable {
    /// Text input without a known physical key, such as an input-method event.
    case unknown
    case enter
    case tab
    case character(String)
    case function(Int)
    case backspace
    case delete
    case insert
    case escape
    case interrupt
    case endOfInput
    case newline
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case first
    case last
    case f2
}
