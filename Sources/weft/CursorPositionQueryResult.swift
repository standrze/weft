import Foundation

/// The completion of an application-requested terminal cursor query.
public struct CursorPositionQueryResult: Equatable, Sendable {
    /// Cursor coordinates are zero-based physical terminal cells.
    public enum Outcome: Equatable, Sendable {
        case position(Point)
        case timedOut
        case cancelled
    }

    public let id: UUID
    public let outcome: Outcome

    public init(id: UUID, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }
}
