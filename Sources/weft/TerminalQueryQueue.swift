import Foundation

/// Bounded query bookkeeping, used only from the session's serial execution context.
internal final class TerminalQueryQueue {
    private struct Pending {
        let id: UUID
        let query: TerminalQuery
        let deadline: TimeInterval
    }
    private let clock: () -> TimeInterval
    private var pending: [Pending] = []
    private var completed: [TerminalQueryResult] = []

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }

    func request(_ query: TerminalQuery, timeoutMilliseconds: Int, write: (Data) throws -> Void) throws -> UUID {
        if case let .privateMode(number) = query, !(1...65535).contains(number) { throw TerminalError.invalidQuery }
        guard !pending.contains(where: { $0.query == query }) else { throw TerminalError.queryAlreadyPending }
        guard pending.count + completed.count < 32 else { throw TerminalError.tooManyQueries }
        try write(Data(query.sequence.utf8))
        let id = UUID()
        let timeout = max(0, min(Int(Int32.max), timeoutMilliseconds))
        pending.append(Pending(id: id, query: query, deadline: clock() + Double(timeout) / 1000))
        return id
    }

    @discardableResult
    func cancel(_ id: UUID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        complete(index: index, outcome: .cancelled)
        return true
    }

    func cancelAll() {
        while !pending.isEmpty { complete(index: 0, outcome: .cancelled) }
    }

    func expire() {
        let now = clock()
        while let index = pending.firstIndex(where: { $0.deadline <= now }) {
            complete(index: index, outcome: .timedOut)
        }
    }

    var nextTimeoutMilliseconds: Int? {
        if !completed.isEmpty { return 0 }
        guard let deadline = pending.map(\.deadline).min() else { return nil }
        return Int(min(Double(Int32.max), max(0, (deadline - clock()) * 1000).rounded(.up)))
    }

    func drainCompletions() -> [InputEvent] {
        let events = completed.map(InputEvent.queryResult)
        completed.removeAll(keepingCapacity: true)
        return events
    }

    func resolve(_ events: [InputEvent], colorSchemeReporting: Bool) -> [InputEvent] {
        var result: [InputEvent] = []
        for event in events {
            guard case var .terminalReply(reply) = event else {
                result.append(event)
                continue
            }
            if case .primaryDeviceAttributes = reply {
                guard pending.contains(where: { $0.query == .kittyKeyboard }) else { continue }
                reply = .kittyKeyboardUnsupported
            }
            if let index = pending.firstIndex(where: { $0.query.matches(reply) }) {
                let request = pending.remove(at: index)
                result.append(
                    .queryResult(TerminalQueryResult(id: request.id, query: request.query, outcome: .reply(reply))))
            } else if colorSchemeReporting, case .colorScheme = reply {
                result.append(.terminalReply(reply))
            }
        }
        return result
    }

    private func complete(index: Int, outcome: TerminalQueryOutcome) {
        let request = pending.remove(at: index)
        completed.append(TerminalQueryResult(id: request.id, query: request.query, outcome: outcome))
    }
}
