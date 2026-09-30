import Foundation
import weft

@main
struct Demo {
    @MainActor
    static func main() async throws {
        let session = try TerminalSession(options: TerminalOptions(alternateScreen: true))
        defer { session.close() }
        let input = TerminalEvents(session: session)
        defer { input.stop() }
        var output = ANSIBackend()
        try output.write(Data("weft / the terminal, untangled.\r\nPress keys. Escape or Ctrl-C exits.\r\n".utf8))

        for try await batch in input.events {
            for event in batch {
                if let key = event.keyboardEvent?.key, [.escape, .interrupt, .endOfInput].contains(key) {
                    return
                }
                if case .signal = event { return }
                try output.write(Data("\(String(reflecting: event))\r\n".utf8))
            }
        }
    }
}
