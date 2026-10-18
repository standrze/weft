#if !os(Windows)
    import Foundation
    import Testing

    @testable import weft

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif

    private func readUntil(_ child: PseudoTerminalProcess, token: String) async throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var output = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let packet = try child.read() else { break }
            output.append(packet)
            if String(decoding: output, as: UTF8.self).contains(token) { return output }
            if packet.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        }
        Issue.record("Child did not emit \(token): \(String(decoding: output, as: UTF8.self))")
        return output
    }

    private func exitStatus(_ child: PseudoTerminalProcess) async throws -> Int32? {
        for _ in 0..<1500 {
            if let status = try child.pollExitStatus() { return status }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Child did not exit")
        return nil
    }

    @Test func childHasControllingTTYAndReceivesResizeInputAndEnvironment() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["WEFT_PTY_FIXTURE"] = "fixture-value"
        let script = """
            test -t 0 && test -t 1 && test -t 2 || exit 99
            printf 'ctty-ok\n' > /dev/tty || exit 98
            stty size
            printf 'env:%s\nready\n' "$WEFT_PTY_FIXTURE"
            read line
            printf 'value:%s\n' "$line"
            stty size
            exit 7
            """
        let child = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment, size: Rect(width: 57, height: 18))
        defer { child.close() }
        let initial = String(decoding: try await readUntil(child, token: "ready"), as: UTF8.self)
        #expect(initial.contains("ctty-ok") && initial.contains("18 57") && initial.contains("env:fixture-value"))
        #expect(try child.pollExitStatus() == nil)
        try child.resize(Rect(width: 101, height: 39))
        #expect(try child.write(Data("ping\n".utf8)) == 5)
        let reply = String(decoding: try await readUntil(child, token: "39 101"), as: UTF8.self)
        #expect(reply.contains("value:ping"))
        #expect(try await exitStatus(child) == 7)
        #expect(try child.pollExitStatus() == 7)
        child.close()
        child.close()
        #expect(throws: TerminalError.sessionClosed) { try child.read() }
        #expect(throws: TerminalError.sessionClosed) { try child.write(Data()) }
        #expect(throws: TerminalError.sessionClosed) { try child.waitForWritable() }
    }

    @Test func childOutputRetainsOSC52AndBinaryBytesAcrossExit() async throws {
        let child = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '\\033]52;c;aGVsbG8=\\007\\377\\000'; exit 3"])
        defer { child.close() }
        #expect(try await exitStatus(child) == 3)
        var output = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var ended = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let packet = try child.read() else {
                ended = true
                break
            }
            output.append(packet)
            if packet.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(ended)
        #expect(output == Data(Array("\u{1B}]52;c;aGVsbG8=\u{7}".utf8) + [0xFF, 0]))
    }

    @Test func childWriteReportsBackpressureAndTerminationIsReaped() async throws {
        let child = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "stty raw -echo; printf ready; exec /bin/sleep 30"])
        defer { child.close() }
        _ = try await readUntil(child, token: "ready")
        let bytes = Data(repeating: 0x61, count: 1_048_576)
        let accepted = try child.write(bytes)
        #expect(accepted >= 0 && accepted <= 8192)
        var sawBackpressure = accepted == 0
        for _ in 0..<100 where !sawBackpressure {
            sawBackpressure = try child.write(bytes) == 0
        }
        #expect(sawBackpressure)
        // Linux can move queued bytes into the line discipline after the first
        // nonblocking write stalls. Keep filling until readiness itself blocks.
        var readinessBlocked = false
        for _ in 0..<100 where !readinessBlocked {
            if try child.waitForWritable(timeoutMilliseconds: 10) {
                _ = try child.write(bytes)
            } else {
                readinessBlocked = true
            }
        }
        #expect(readinessBlocked)
        try child.terminate()
        #expect(try await exitStatus(child) == 143)
    }

    @Test func closingRunningChildReleasesAndReapsItsOwnedProcess() async throws {
        let child = try PseudoTerminalProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let pid = child.processIdentifier
        child.close()
        child.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if kill(pid, 0) < 0, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Closed child is still running or unreaped")
    }

    @Test func childSpawnRejectsMissingExecutablesAndInvalidArguments() {
        #expect(throws: TerminalError.self) {
            try PseudoTerminalProcess(executable: URL(fileURLWithPath: "/missing-weft-pty-executable"))
        }
        #expect(throws: TerminalError.configurationFailed(operation: "child arguments", code: EINVAL)) {
            try PseudoTerminalProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["a\u{0}b"])
        }
        #expect(throws: TerminalError.configurationFailed(operation: "child arguments", code: EINVAL)) {
            try PseudoTerminalProcess(executable: URL(fileURLWithPath: "/bin/sh"), environment: ["BAD=KEY": "value"])
        }
    }

    @Test(arguments: 0..<12)
    func childReceivesControlCThroughItsControllingTerminal(_ trial: Int) async throws {
        let child = try PseudoTerminalProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        defer { child.close() }
        var accepted = 0
        for _ in 0..<1500 where accepted == 0 {
            accepted = try child.write(Data([3]))
            if accepted == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(accepted == 1)
        #expect(try await exitStatus(child) == 130)
    }

    @Test func largeChildOutputDrainsInBoundedReadsWithoutDroppingFinalBytes() async throws {
        let child = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=8192 count=160 2>/dev/null; printf end; exit 9"])
        defer { child.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var output = Data()
        var status: Int32?
        var ended = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let packet = try child.read() else {
                ended = true
                break
            }
            #expect(packet.count <= 8192)
            output.append(packet)
            status = try child.pollExitStatus()
            if packet.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(ended)
        #expect(output == Data(repeating: 0, count: 8192 * 160) + Data("end".utf8))
        if status == nil { status = try await exitStatus(child) }
        #expect(status == 9)
    }

    @Test func childArgumentsRemainLiteralThroughTheMacOSForegroundBootstrap() async throws {
        let literal = #"spaces ' \" ; $(printf BAD) `printf BAD` 日本語"#
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        try Data("printf BADPROFILE".utf8).write(to: profile)
        var environment = ProcessInfo.processInfo.environment
        environment["ENV"] = profile.path
        environment["BASH_ENV"] = profile.path
        let child = try PseudoTerminalProcess(
            executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal], environment: environment)
        defer { child.close() }
        #expect(try await exitStatus(child) == 0)
        var output = Data()
        while let packet = try child.read() {
            output.append(packet)
            if packet.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(output == Data(literal.utf8))
    }

#endif
