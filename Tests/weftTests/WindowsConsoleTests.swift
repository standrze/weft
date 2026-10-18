#if os(Windows)
    import CWeft
    import Foundation
    import Testing

    @testable import weft

    /// Opt-in fixture detaches this test process and allocates its own console before any mutation.
    ///
    /// Run in a separate filtered test process via scripts/smoke-windows.ps1.
    @Suite(.serialized)
    struct WindowsConsoleTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_WINDOWS_CONSOLE_TEST"] == "1"))
        @MainActor
        func nativeModesInputResizeReadinessAndRestoration() async throws {
            try #require(weft_console_test_private() == 0)
            defer { weft_console_test_private_end() }
            let original = consoleState()
            var canonicalOptions = TerminalOptions()
            canonicalOptions.rawMode = false
            #expect(throws: TerminalError.unsupportedOperation(operation: "Windows canonical console input")) {
                _ = try TerminalSession(options: canonicalOptions)
            }
            #expect(consoleState() == original)
            var options = TerminalOptions()
            options.hideCursor = false
            let session = try TerminalSession(options: options)
            defer { session.close() }
            let configured = consoleState()
            #expect(configured[0] & 0x0006 == 0)  // No line input or echo in raw mode.
            #expect(configured[1] & 0x0004 != 0)  // VT output.
            #expect(configured[2] == 65001)
            #expect(configured[3] == 65001)

            let handoffValue = try session.withSuspendedTerminal {
                #expect(consoleState() == original)
                #expect(session.isSuspended)
                return 42
            }
            #expect(handoffValue == 42)
            #expect(!session.isSuspended)
            #expect(consoleState() == configured)
            #expect(weft_console_test_key(0x68, 0, 0) != 0)
            #expect(try poll(session, until: .text("h")))

            enum HandoffFailure: Error, Equatable { case expected }
            #expect(throws: HandoffFailure.expected) {
                try session.withSuspendedTerminal {
                    #expect(consoleState() == original)
                    #expect(session.isSuspended)
                    throw HandoffFailure.expected
                }
            }
            #expect(!session.isSuspended)
            #expect(consoleState() == configured)
            #expect(weft_console_test_key(0x72, 0, 0) != 0)
            #expect(try poll(session, until: .text("r")))

            #expect(weft_console_test_key(0x754c, 0, 0) != 0)
            #expect(try poll(session, until: .text("界")))
            #expect(weft_console_test_key(0, 0x26, 0) != 0)  // VK_UP.
            #expect(try poll(session, until: .key(.up)))
            #expect(weft_console_test_key(0xd83d, 0, 0) != 0)
            #expect(weft_console_test_key(0xde00, 0, 0) != 0)
            #expect(try poll(session, until: .text("😀")))

            #expect(weft_console_test_resize(60, 20) != 0)
            #expect(try poll(session, until: .resize(60, 20)))
            session.close()
            #expect(consoleState() == original)

            // Byte polling uses the same reconstructed stream, with no second native reader.
            let bytesSession = try TerminalSession(options: options)
            #expect(weft_console_test_key(0x00e9, 0, 0) != 0)
            var collected = Data()
            for _ in 0..<32 {
                for event in try bytesSession.pollBytes(timeoutMilliseconds: 100) {
                    if case .bytes(let bytes) = event { collected.append(bytes) }
                }
                if !collected.isEmpty { break }
            }
            #expect(String(decoding: collected, as: UTF8.self) == "é")
            bytesSession.close()
            #expect(consoleState() == original)

            // A waiter observes readiness but does not consume the queued key.
            let readinessSession = try TerminalSession(options: options)
            let waiter = try #require(weft_console_waiter_create())
            defer { weft_console_waiter_destroy(waiter) }
            #expect(weft_console_test_key(0x78, 0, 0) != 0)
            #expect(weft_console_waiter_wait(waiter) == 1)
            #expect(try poll(readinessSession, until: .text("x")))
            weft_console_waiter_cancel(waiter)
            #expect(weft_console_waiter_wait(waiter) == 0)
            readinessSession.close()

            let asynchronousSession = try TerminalSession(options: options)
            let events = TerminalEvents(session: asynchronousSession)
            #expect(weft_console_test_key(0x79, 0, 0) != 0)
            let received = try await firstBatch(events)
            #expect(received.contains(.text("y")))
            events.stop()
            #expect(weft_console_test_interrupt() != 0)
            #expect(try poll(asynchronousSession, until: .signal(2)))
            asynchronousSession.close()
            #expect(consoleState() == original)
        }

        private func poll(_ session: TerminalSession, until expected: InputEvent) throws -> Bool {
            for _ in 0..<32 {
                if try session.poll(timeoutMilliseconds: 100).contains(expected) { return true }
            }
            return false
        }

        private func consoleState() -> [UInt32] {
            var input: UInt32 = 0
            var output: UInt32 = 0
            var inputCP: UInt32 = 0
            var outputCP: UInt32 = 0
            weft_console_test_state(&input, &output, &inputCP, &outputCP)
            return [input, output, inputCP, outputCP]
        }

        @MainActor
        private func firstBatch(_ source: TerminalEvents) async throws -> [InputEvent] {
            let stream = source.events
            return try await withThrowingTaskGroup(of: [InputEvent].self) { group in
                group.addTask {
                    for try await batch in stream {
                        if batch.contains(.text("y")) { return batch }
                    }
                    return []
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw TerminalError.inputClosed
                }
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
        }
    }
#endif
