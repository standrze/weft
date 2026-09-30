import Foundation
import Testing

@testable import weft

private final class SessionDriver: TerminalSessionDriver {
    var beginCount = 0
    var endCount = 0
    var beganWithRawMode: Bool?
    var beginError: TerminalError?
    var failedWrites: Set<Int> = []
    var writes: [String] = []
    var size = Rect(width: 80, height: 24)
    var signalNumber: Int32 = 0
    var signalDuringRead: Int32 = 0
    var pendingBytes: [UInt8] = []
    var lastTimeout: Int32?

    func begin(rawMode: Bool) throws {
        beginCount += 1
        if let beginError { throw beginError }
        beganWithRawMode = rawMode
    }

    func end() { endCount += 1 }

    func write(_ data: Data) throws {
        writes.append(String(decoding: data, as: UTF8.self))
        if failedWrites.contains(writes.count) { throw TerminalError.outputFailed }
    }

    func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int {
        lastTimeout = timeoutMilliseconds
        signalNumber = signalDuringRead
        let count = min(bytes.count, pendingBytes.count)
        bytes.replaceSubrange(0..<count, with: pendingBytes.prefix(count))
        pendingBytes.removeFirst(count)
        return count
    }
}

@Test func defaultSessionKeepsShellHistoryScreenAndNativeSelection() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    #expect(driver.beganWithRawMode == true)
    #expect(!session.mouseEnabled)
    #expect(driver.writes == ["\u{1b}[?2004h"])
    session.close()
    #expect(driver.endCount == 1)
    #expect(driver.writes.last == "\u{1b}[?2026l\u{1b}[0m\u{1b}[?2004l")
}

@Test func fullScreenSessionClearsHistoryBeforeSwitchAndPopsKeyboardBeforeLeaving() throws {
    let driver = SessionDriver()
    let options = TerminalOptions(
        alternateScreen: true,
        clearScreen: true,
        clearScrollback: true,
        hideCursor: true,
        cursorStyle: .blinkingBlock,
        mouseCapture: true,
        keyboardProtocol: .kitty
    )
    let session = try TerminalSession(options: options, driver: driver)
    let entry = try #require(driver.writes.first)
    let historyClear = try #require(entry.range(of: "\u{1b}[3J"))
    let alternateScreen = try #require(entry.range(of: "\u{1b}[?1049h"))
    #expect(historyClear.lowerBound < alternateScreen.lowerBound)
    #expect(entry.contains("\u{1b}[1 q"))
    #expect(entry.hasSuffix("\u{1b}[>31u"))
    #expect(session.mouseEnabled)
    session.close()
    let exit = try #require(driver.writes.last)
    let keyboardPop = try #require(exit.range(of: "\u{1b}[<u"))
    let primaryScreen = try #require(exit.range(of: "\u{1b}[?1049l"))
    let cursorReset = try #require(exit.range(of: "\u{1b}[0 q"))
    #expect(keyboardPop.lowerBound < primaryScreen.lowerBound)
    #expect(cursorReset.lowerBound < primaryScreen.lowerBound)
    #expect(exit.contains("\u{1b}[?1002l\u{1b}[?1006l"))
    #expect(exit.contains("\u{1b}[?25h"))
}

@Test func failedEntryRestoresModesAndSettingsExactlyOnce() throws {
    let driver = SessionDriver()
    driver.failedWrites = [1]
    #expect(throws: TerminalError.outputFailed) {
        try TerminalSession(
            options: TerminalOptions(alternateScreen: true, hideCursor: true, cursorStyle: .blinkingBlock),
            driver: driver)
    }
    #expect(driver.beginCount == 1)
    #expect(driver.endCount == 1)
    #expect(driver.writes.count == 2)
    #expect(driver.writes.last?.hasSuffix("\u{1b}[0 q\u{1b}[?25h\u{1b}[?1049l") == true)
}

@Test func sessionThatFailsToAcquireOwnershipDoesNotRestoreAnotherSession() {
    let driver = SessionDriver()
    driver.beginError = .sessionAlreadyActive
    #expect(throws: TerminalError.sessionAlreadyActive) {
        try TerminalSession(options: TerminalOptions(), driver: driver)
    }
    #expect(driver.endCount == 0)
    #expect(driver.writes.isEmpty)
}

@Test func closeRestoresSettingsEvenWhenOutputFailsAndRejectsFurtherUse() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    driver.failedWrites = [2]
    session.close()
    session.close()
    #expect(driver.endCount == 1)
    #expect(driver.writes.count == 2)
    #expect(throws: TerminalError.sessionClosed) { try session.poll() }
    #expect(throws: TerminalError.sessionClosed) { try session.setMouseEnabled(true) }
    #expect(throws: TerminalError.sessionClosed) { try session.copyUsingOSC52("copied") }
}

@Test func dynamicMouseCaptureIsRestoredAndFailedToggleKeepsItsPreviousState() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    try session.setMouseEnabled(true)
    #expect(session.mouseEnabled)
    driver.failedWrites = [3]
    #expect(throws: TerminalError.outputFailed) { try session.setMouseEnabled(false) }
    #expect(session.mouseEnabled)
    #expect(driver.writes.last == "\u{1b}[?1002h\u{1b}[?1006h")
    session.close()
    #expect(driver.writes.last?.contains("\u{1b}[?1002l\u{1b}[?1006l") == true)
}

@Test func pollReportsSignalArrivingDuringReadAndClampsTimeout() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    driver.signalDuringRead = 15
    #expect(try session.poll(timeoutMilliseconds: Int.max) == [.signal(15)])
    #expect(driver.lastTimeout == Int32.max)
}

@Test func pollReportsResizeAndSupportsCanonicalInput() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(rawMode: false), driver: driver)
    defer { session.close() }
    #expect(driver.beganWithRawMode == false)
    driver.size = Rect(width: 100, height: 40)
    driver.pendingBytes = Array("hi".utf8)
    #expect(try session.poll(timeoutMilliseconds: 0) == [.text("h"), .text("i"), .resize(100, 40)])
    #expect(driver.lastTimeout == 0)
}

@Test func pendingResizeNeverWaitsIndefinitelyForKeyboardInput() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    driver.size = Rect(width: 120, height: 50)
    #expect(try session.poll(timeoutMilliseconds: -1) == [.resize(120, 50)])
    #expect(driver.lastTimeout == 0)
}

@Test func hoverTrackingIsOptInAndReleasedForNativeSelectionAndExit() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(mouseCapture: true), driver: driver)
    #expect(!session.mouseMotionEnabled)
    try session.setMouseEnabled(true, reportMotion: true)
    #expect(session.mouseMotionEnabled)
    #expect(driver.writes.last?.contains("\u{1b}[?1003h") == true)
    let count = driver.writes.count
    try session.setMouseEnabled(true, reportMotion: true)
    #expect(driver.writes.count == count)
    try session.setMouseEnabled(false)
    #expect(!session.mouseEnabled && !session.mouseMotionEnabled)
    #expect(driver.writes.last?.contains("\u{1b}[?1003l") == true)
    try session.setMouseEnabled(true, reportMotion: true)
    session.close()
    #expect(driver.writes.last?.contains("\u{1b}[?1003l") == true)
    #expect(!session.mouseMotionEnabled)
}

@Test func failedHoverTransitionRestoresPreviousTrackingMode() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(mouseCapture: true), driver: driver)
    defer { session.close() }
    driver.failedWrites = [2]
    #expect(throws: TerminalError.outputFailed) { try session.setMouseEnabled(true, reportMotion: true) }
    #expect(session.mouseEnabled && !session.mouseMotionEnabled)
    #expect(driver.writes.last?.contains("\u{1b}[?1003l\u{1b}[?1002h") == true)
    try session.setMouseEnabled(true, reportMotion: true)
    driver.failedWrites.insert(driver.writes.count + 1)
    #expect(throws: TerminalError.outputFailed) { try session.setMouseEnabled(false) }
    #expect(session.mouseEnabled && session.mouseMotionEnabled)
    #expect(driver.writes.last?.contains("\u{1b}[?1003h") == true)
}
