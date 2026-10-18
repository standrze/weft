import Foundation
import Testing

@testable import weft

private final class SessionDriver: TerminalSessionDriver {
    var inputDescriptor: Int32 = -1
    var beginCount = 0
    var endCount = 0
    var beganWithRawMode: Bool?
    var beginError: TerminalError?
    var failedWrites: Set<Int> = []
    var writes: [String] = []
    var dataWrites: [Data] = []
    var size = Rect(width: 80, height: 24)
    var signalNumber: Int32 = 0
    var signalDuringRead: Int32 = 0
    var pendingBytes: [UInt8] = []
    var lastTimeout: Int32?
    var readCount = 0
    var onRead: (() -> Void)?

    func begin(rawMode: Bool) throws {
        beginCount += 1
        if let beginError { throw beginError }
        beganWithRawMode = rawMode
    }

    func end() { endCount += 1 }

    func write(_ data: Data) throws {
        dataWrites.append(data)
        writes.append(String(decoding: data, as: UTF8.self))
        if failedWrites.contains(writes.count) { throw TerminalError.outputFailed }
    }

    func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) -> Int {
        lastTimeout = timeoutMilliseconds
        readCount += 1
        onRead?()
        signalNumber = signalDuringRead
        let count = min(bytes.count, pendingBytes.count)
        bytes.replaceSubrange(0..<count, with: pendingBytes.prefix(count))
        pendingBytes.removeFirst(count)
        return count
    }
}

@Test func escapeDeadlineCapsBlockingPollAndPreservesFragmentsUntilConfiguredTimeout() throws {
    let driver = SessionDriver()
    var time: TimeInterval = 0
    let session = try TerminalSession(
        options: TerminalOptions(escapeTimeoutMilliseconds: 150), driver: driver, clock: { time })
    defer { session.close() }
    driver.pendingBytes = [27]
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
    time = 0.05
    #expect(session.pendingEscapeTimeoutMilliseconds == 100)
    #expect(try session.poll(timeoutMilliseconds: -1).isEmpty)
    #expect(driver.lastTimeout == 100)
    driver.pendingBytes = [91, 65]
    #expect(try session.poll(timeoutMilliseconds: 0) == [.key(.up)])
    #expect(session.pendingEscapeTimeoutMilliseconds == nil)
    driver.pendingBytes = [27]
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
    driver.onRead = { time += Double(driver.lastTimeout ?? 0) / 1000 }
    #expect(try session.poll(timeoutMilliseconds: -1) == [.key(.escape)])
    #expect(driver.lastTimeout == 150)
    #expect(session.pendingEscapeTimeoutMilliseconds == nil)
    driver.onRead = nil
    driver.pendingBytes = [27]
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
    time += 1
    driver.pendingBytes = [120]
    #expect(try session.poll(timeoutMilliseconds: -1) == [.key(.escape), .text("x")])
    #expect(driver.lastTimeout == 0)
}

@Test func escapeTimeoutNormalizesLimitsAndZeroResolvesImmediately() throws {
    #expect(TerminalOptions().escapeTimeoutMilliseconds == 35)
    #expect(TerminalOptions(escapeTimeoutMilliseconds: -1).escapeTimeoutMilliseconds == 0)
    #expect(TerminalOptions(escapeTimeoutMilliseconds: Int.max).escapeTimeoutMilliseconds == Int(Int32.max))
    let driver = SessionDriver()
    var options = TerminalOptions()
    options.escapeTimeoutMilliseconds = -100
    let session = try TerminalSession(options: options, driver: driver)
    defer { session.close() }
    driver.pendingBytes = [27]
    #expect(try session.poll(timeoutMilliseconds: 0) == [.key(.escape)])
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
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

@Test func bytePollingPreservesPartialProtocolsAndReportsResizeWithoutWaiting() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(bracketedPaste: false), driver: driver)
    defer { session.close() }
    let fragments: [[UInt8]] = [[0x1B], [0x5B, 0x32, 0x30, 0x30, 0x7E, 0xE7], [0x95, 0x8C, 0x00, 0xFF]]
    for fragment in fragments {
        driver.pendingBytes = fragment
        #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.bytes(Data(fragment))])
    }
    #expect(try session.pollBytes(timeoutMilliseconds: 0).isEmpty)
    driver.size = Rect(width: 110, height: 37)
    driver.pendingBytes = [0x1B, 0x5B, 0x3C]
    let events = try session.pollBytes(timeoutMilliseconds: -1)
    #expect(events == [.bytes(Data([0x1B, 0x5B, 0x3C])), .resize(110, 37)])
    #expect(driver.lastTimeout == 0)
    #expect(try session.pollBytes(timeoutMilliseconds: 0).isEmpty)
}

@Test(arguments: [true, false])
func sessionInputModeCannotLoseBytesBySwitchingDecoders(bytesFirst: Bool) throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    driver.pendingBytes = [0x1B]
    if bytesFirst {
        _ = try session.pollBytes(timeoutMilliseconds: 0)
        #expect(throws: TerminalError.inputModeConflict) { try session.poll(timeoutMilliseconds: 0) }
    } else {
        _ = try session.poll(timeoutMilliseconds: 0)
        #expect(throws: TerminalError.inputModeConflict) { try session.pollBytes(timeoutMilliseconds: 0) }
    }
    driver.pendingBytes = bytesFirst ? [0x41] : [0x5B, 0x41]
    if bytesFirst {
        #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.bytes(Data([0x41]))])
    } else {
        #expect(try session.poll(timeoutMilliseconds: 0) == [.key(.up)])
    }
}

@Test func bytePollingKeepsTerminationAndWriteFailureCleanup() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(bracketedPaste: false), driver: driver)
    let output = Data([0x1B, 0x5D, 0x00, 0xFF])
    try session.writeBytes(output)
    #expect(driver.dataWrites.last == output)
    driver.signalDuringRead = 15
    #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.signal(15)])
    driver.failedWrites.insert(driver.writes.count + 1)
    #expect(throws: TerminalError.outputFailed) { try session.writeBytes(output) }
    session.close()
    #expect(driver.endCount == 1)
    #expect(throws: TerminalError.sessionClosed) { try session.pollBytes() }
    #expect(throws: TerminalError.sessionClosed) { try session.writeBytes(output) }
}

@Test func focusReportingIsOptInAndRestoredOnCloseAndFailedInitialization() throws {
    let defaults = TerminalOptions()
    #expect(!defaults.focusReporting)
    #expect(!defaults.enterSequence.contains("\u{1b}[?1004h"))
    #expect(!defaults.leaveSequence(mouseEnabled: false).contains("\u{1b}[?1004l"))
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(focusReporting: true), driver: driver)
    #expect(driver.writes[0].contains("\u{1b}[?1004h"))
    driver.pendingBytes = Array("\u{1b}[O\u{1b}[I".utf8)
    #expect(try session.poll(timeoutMilliseconds: 0) == [.focusChanged(false), .focusChanged(true)])
    session.close()
    #expect(driver.writes.last?.contains("\u{1b}[?1004l") == true)
    #expect(driver.endCount == 1)
    session.close()
    #expect(driver.endCount == 1)
    let failed = SessionDriver()
    failed.failedWrites = [1]
    #expect(throws: TerminalError.outputFailed) {
        _ = try TerminalSession(options: TerminalOptions(focusReporting: true), driver: failed)
    }
    #expect(failed.writes.last?.contains("\u{1b}[?1004l") == true)
    #expect(failed.endCount == 1)
}

@Test func inputOnlySessionPreservesANSIStateAndCanPollNotificationsUnderBackpressure() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(bracketedPaste: false), driver: driver)
    driver.pendingBytes = [65, 27, 255]
    driver.size = Rect(width: 101, height: 39)
    #expect(try session.pollBytes(readInput: false) == [.resize(101, 39)])
    #expect(driver.pendingBytes == [65, 27, 255] && driver.lastTimeout == nil)
    driver.signalNumber = 15
    #expect(try session.pollBytes(readInput: false) == [.signal(15)])
    driver.signalNumber = 0
    #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.bytes(Data([65, 27, 255]))])
    session.close()
    session.close()
    #expect(driver.dataWrites.allSatisfy(\.isEmpty) && driver.endCount == 1)
}

@Test func suspendResumePreservesDynamicModesWithoutClearingHistoryAgain() throws {
    let driver = SessionDriver()
    let options = TerminalOptions(
        alternateScreen: true, clearScreen: true, clearScrollback: true,
        hideCursor: true, mouseCapture: true, focusReporting: true, colorSchemeReporting: true,
        keyboardProtocol: .kitty)
    let session = try TerminalSession(options: options, driver: driver)
    try session.setMouseEnabled(true, reportMotion: true)
    let query = try session.requestQuery(.backgroundColor)
    driver.pendingBytes = [27]
    _ = try session.poll(timeoutMilliseconds: 0)
    try session.suspend()
    try session.suspend()
    #expect(session.isSuspended && !session.mouseEnabled && !session.mouseMotionEnabled)
    #expect(driver.endCount == 1)
    #expect(driver.writes.last?.contains("\u{1b}[?2031l") == true)
    #expect(throws: TerminalError.sessionSuspended) { try session.poll() }
    #expect(throws: TerminalError.sessionSuspended) { try session.writeBytes(Data()) }
    driver.size = Rect(width: 100, height: 40)
    try session.resume()
    #expect(!session.isSuspended && session.mouseEnabled && session.mouseMotionEnabled)
    #expect(driver.beginCount == 2)
    let entry = try #require(driver.writes.last)
    #expect(!entry.contains("\u{1b}[3J") && !entry.contains("\u{1b}[2J"))
    #expect(entry.contains("\u{1b}[?1003h") && entry.contains("\u{1b}[?2031h"))
    driver.pendingBytes = [120]
    #expect(
        try session.poll(timeoutMilliseconds: -1) == [
            .queryResult(TerminalQueryResult(id: query, query: .backgroundColor, outcome: .cancelled)),
            .terminalResumed, .text("x"), .resize(100, 40),
        ])
    #expect(driver.lastTimeout == 0)
    try session.resume()
    #expect(driver.beginCount == 2)
    session.close()
    #expect(driver.endCount == 2)
}

@Test func handoffRestoresOnOperationFailureAndRetainsBothErrorsWhenResumeFails() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    #expect(throws: TerminalError.inputClosed) {
        try session.withSuspendedTerminal {
            #expect(session.isSuspended && driver.endCount == 1)
            throw TerminalError.inputClosed
        }
    }
    #expect(!session.isSuspended && driver.beginCount == 2)
    do {
        try session.withSuspendedTerminal {
            driver.failedWrites.insert(driver.writes.count + 1)
            throw TerminalError.inputClosed
        }
        Issue.record("Handoff should have failed")
    } catch let error as TerminalHandoffError {
        #expect(error.operationError as? TerminalError == .inputClosed)
        #expect(error.resumeError as? TerminalError == .outputFailed)
    }
    #expect(session.isSuspended && driver.endCount == 3)
    driver.failedWrites = []
    try session.resume()
    #expect(!session.isSuspended)
}

@Test func suspendOutputFailureStillReleasesOwnershipAndClosingSuspendedSessionDoesNotTouchTTY() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    driver.failedWrites = [2]
    #expect(throws: TerminalError.outputFailed) { try session.suspend() }
    #expect(session.isSuspended && driver.endCount == 1)
    driver.beginError = .sessionAlreadyActive
    #expect(throws: TerminalError.sessionAlreadyActive) { try session.resume() }
    #expect(session.isSuspended && driver.endCount == 1)
    let writeCount = driver.writes.count
    session.close()
    session.close()
    #expect(driver.writes.count == writeCount && driver.endCount == 1)
    #expect(throws: TerminalError.sessionClosed) { try session.resume() }
}

@Test func queriesCorrelateRepliesWithoutLosingKeysAndRejectDuplicateOrInvalidRequests() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    let cursor = try session.requestQuery(.cursorPosition)
    let keyboard = try session.requestQuery(.kittyKeyboard)
    #expect(driver.writes.suffix(2) == ["\u{1b}[6n", "\u{1b}[?u\u{1b}[c"])
    #expect(throws: TerminalError.queryAlreadyPending) { try session.requestQuery(.cursorPosition) }
    #expect(throws: TerminalError.invalidQuery) { try session.requestQuery(.privateMode(-1)) }
    driver.pendingBytes = Array("x\u{1b}[2;3R\u{1b}[?0u\u{1b}[?1;2cy".utf8)
    #expect(
        try session.poll(timeoutMilliseconds: 0) == [
            .text("x"),
            .queryResult(
                TerminalQueryResult(
                    id: cursor, query: .cursorPosition,
                    outcome: .reply(.cursorPosition(Point(x: 2, y: 1))))),
            .queryResult(
                TerminalQueryResult(id: keyboard, query: .kittyKeyboard, outcome: .reply(.kittyKeyboard(flags: 0)))),
            .text("y"),
        ])
    let unsupported = try session.requestQuery(.kittyKeyboard)
    driver.pendingBytes = Array("\u{1b}[?1;2c".utf8)
    #expect(
        try session.poll(timeoutMilliseconds: 0) == [
            .queryResult(
                TerminalQueryResult(id: unsupported, query: .kittyKeyboard, outcome: .reply(.kittyKeyboardUnsupported)))
        ])
    driver.failedWrites.insert(driver.writes.count + 1)
    #expect(throws: TerminalError.outputFailed) { try session.requestQuery(.foregroundColor) }
    driver.failedWrites = []
    let retry = try session.requestQuery(.foregroundColor)
    #expect(session.cancelQuery(retry))
}

@Test func queryDeadlinesBoundIndefinitePollAndCancellationAndLateRepliesAreExplicit() throws {
    let driver = SessionDriver()
    var time: TimeInterval = 0
    let session = try TerminalSession(options: TerminalOptions(), driver: driver, clock: { time })
    defer { session.close() }
    let background = try session.requestQuery(.backgroundColor, timeoutMilliseconds: 100)
    let mode = try session.requestQuery(.privateMode(2026), timeoutMilliseconds: 200)
    driver.onRead = { time += Double(driver.lastTimeout ?? 0) / 1000 }
    #expect(
        try session.poll(timeoutMilliseconds: -1) == [
            .queryResult(TerminalQueryResult(id: background, query: .backgroundColor, outcome: .timedOut))
        ])
    #expect(driver.lastTimeout == 100)
    #expect(session.cancelQuery(mode))
    #expect(!session.cancelQuery(mode))
    driver.pendingBytes = Array("\u{1b}]11;rgb:0000/0000/0000\u{7}x".utf8)
    #expect(
        try session.poll(timeoutMilliseconds: -1) == [
            .queryResult(TerminalQueryResult(id: mode, query: .privateMode(2026), outcome: .cancelled)), .text("x"),
        ])
    #expect(driver.lastTimeout == 0)
    for number in 1...32 { try session.requestQuery(.privateMode(number)) }
    #expect(throws: TerminalError.tooManyQueries) { try session.requestQuery(.cursorPosition) }
}

@Test func themeReportingIsOptInAndQueriedReportsStaySeparateFromUnsolicitedUpdates() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(colorSchemeReporting: true), driver: driver)
    defer { session.close() }
    let query = try session.requestQuery(.colorScheme)
    driver.pendingBytes = Array("\u{1b}[?997;1n\u{1b}[?997;2nx".utf8)
    #expect(
        try session.poll(timeoutMilliseconds: 0) == [
            .queryResult(TerminalQueryResult(id: query, query: .colorScheme, outcome: .reply(.colorScheme(.dark)))),
            .terminalReply(.colorScheme(.light)), .text("x"),
        ])
    let silentDriver = SessionDriver()
    let silent = try TerminalSession(options: TerminalOptions(), driver: silentDriver)
    defer { silent.close() }
    silentDriver.pendingBytes = Array("\u{1b}[?997;1nx".utf8)
    #expect(try silent.poll(timeoutMilliseconds: 0) == [.text("x")])
}

@MainActor @Test func asyncQueryTimeoutAndInputOwnershipWorkWithoutInputReadiness() async throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    let source = TerminalEvents(session: session)
    defer { source.stop() }
    #expect(throws: TerminalError.inputSourceActive) { try session.poll() }
    let duplicate = TerminalEvents(session: session)
    var duplicateIterator = duplicate.events.makeAsyncIterator()
    do {
        _ = try await duplicateIterator.next()
        Issue.record("A second input source should fail")
    } catch {
        #expect(error as? TerminalError == .inputSourceActive)
    }
    let query = try session.requestQuery(.backgroundColor, timeoutMilliseconds: 10)
    let watchdog = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        Issue.record("Query timeout did not wake the async reader")
        source.stop()
    }
    defer { watchdog.cancel() }
    var iterator = source.events.makeAsyncIterator()
    #expect(
        try await iterator.next() == [
            .queryResult(TerminalQueryResult(id: query, query: .backgroundColor, outcome: .timedOut))
        ])
    source.stop()
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
}

@MainActor @Test func asyncInputPausesForHandoffResumesAndFinishesOnClose() async throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    let source = TerminalEvents(session: session)
    defer {
        source.stop()
        session.close()
    }
    let query = try session.requestQuery(.foregroundColor, timeoutMilliseconds: 5)
    try session.suspend()
    let readCount = driver.readCount
    try await Task.sleep(for: .milliseconds(20))
    #expect(driver.readCount == readCount)
    driver.pendingBytes = [120]
    try session.resume()
    var iterator = source.events.makeAsyncIterator()
    #expect(
        try await iterator.next() == [
            .queryResult(TerminalQueryResult(id: query, query: .foregroundColor, outcome: .cancelled)),
            .terminalResumed, .text("x"),
        ])
    try session.suspend()
    session.close()
    #expect(try await iterator.next() == nil)
}

@MainActor @Test func releasingAsyncSourceReleasesItsReaderReservation() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    var source: TerminalEvents? = TerminalEvents(session: session)
    #expect(source != nil)
    source = nil
    #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
}

@Test func failedQueriesDoNotChooseDecodedInputAndRawResumePreservesBytes() throws {
    let driver = SessionDriver()
    let session = try TerminalSession(options: TerminalOptions(), driver: driver)
    defer { session.close() }
    #expect(throws: TerminalError.invalidQuery) { try session.requestQuery(.privateMode(0)) }
    driver.failedWrites = [2]
    #expect(throws: TerminalError.outputFailed) { try session.requestQuery(.cursorPosition) }
    driver.failedWrites = []
    driver.pendingBytes = [27, 255]
    #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.bytes(Data([27, 255]))])
    #expect(throws: TerminalError.inputModeConflict) { try session.requestQuery(.backgroundColor) }
    try session.suspend()
    try session.resume()
    driver.pendingBytes = [0, 65]
    #expect(try session.pollBytes(timeoutMilliseconds: -1, readInput: false) == [.terminalResumed])
    #expect(try session.pollBytes(timeoutMilliseconds: 0) == [.bytes(Data([0, 65]))])
    try session.suspend()
    try session.resume()
    #expect(try session.pollBytes(timeoutMilliseconds: -1) == [.terminalResumed])
    #expect(driver.lastTimeout == 0)
}

@Test func simultaneousQueryDeadlinesCompleteInRequestOrder() throws {
    let driver = SessionDriver()
    var time: TimeInterval = 0
    let session = try TerminalSession(options: TerminalOptions(), driver: driver, clock: { time })
    defer { session.close() }
    let first = try session.requestQuery(.foregroundColor, timeoutMilliseconds: 10)
    let second = try session.requestQuery(.backgroundColor, timeoutMilliseconds: 10)
    time = 1
    #expect(
        try session.poll(timeoutMilliseconds: -1) == [
            .queryResult(TerminalQueryResult(id: first, query: .foregroundColor, outcome: .timedOut)),
            .queryResult(TerminalQueryResult(id: second, query: .backgroundColor, outcome: .timedOut)),
        ])
    #expect(driver.lastTimeout == 0)
}

#if os(Windows)
    @Test func windowsShellSuspensionFailsWithoutReleasingOwnership() throws {
        let driver = SessionDriver()
        let session = try TerminalSession(options: TerminalOptions(), driver: driver)
        defer { session.close() }
        #expect(throws: TerminalError.unsupportedOperation(operation: "POSIX shell job control")) {
            try session.suspendToShell()
        }
        #expect(!session.isSuspended)
        #expect(try session.poll(timeoutMilliseconds: 0).isEmpty)
    }
#endif
