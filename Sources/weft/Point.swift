/// Integer terminal coordinates.
///
/// A column is a terminal cell, not a Unicode scalar.
public struct Point: Equatable, Comparable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// Orders positions by row, then by column.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}
