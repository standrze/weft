/// A rectangular region measured in terminal cells.
public struct Rect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// The column immediately after the rectangle's right edge.
    public var maxX: Int {
        x + width
    }

    /// The row immediately after the rectangle's bottom edge.
    public var maxY: Int {
        y + height
    }

    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    /// Insets all four edges by the same number of cells.
    public func inset(_ amount: Int = 1) -> Rect {
        Rect(
            x: x + amount,
            y: y + amount,
            width: width - 2 * amount,
            height: height - 2 * amount
        )
    }
}
