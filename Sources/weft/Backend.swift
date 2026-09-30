import Foundation

/// An output destination for terminal bytes.
public protocol Backend {
    /// Writes every byte in order or throws an error.
    mutating func write(_ data: Data) throws
}
