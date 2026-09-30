import Foundation
import Testing
import weft

private struct RecordingBackend: Backend {
    var output: [Data] = []

    mutating func write(_ data: Data) {
        output.append(data)
    }
}

@Test func commandsWorkWithoutImportingLoom() throws {
    var backend = RecordingBackend()
    try backend.execute([])
    #expect(backend.output.isEmpty)
    try backend.execute([.clearScreen, .moveCursor(Point(x: 4, y: 2)), .cursorVisible(false)])
    #expect(backend.output.count == 1)
    #expect(String(decoding: backend.output[0], as: UTF8.self) == "\u{1b}[2J\u{1b}[H\u{1b}[3;5H\u{1b}[?25l")
}

@Test func terminalEventsAndWidthsWorkWithoutLoom() {
    var decoder = InputDecoder()
    #expect(
        decoder.feed(Array("\u{1b}[<0;3;4M".utf8)) == [.mouse(MouseEvent(kind: .down, position: Point(x: 2, y: 3)))])
    #expect(decoder.feed(Array("\u{1b}[200~hello\nworld\u{1b}[201~".utf8)) == [.paste("hello\nworld")])
    #expect(terminalCellWidth("界") == 2)
}
