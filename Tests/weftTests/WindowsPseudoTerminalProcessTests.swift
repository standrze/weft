#if os(Windows)
    import Foundation
    import Testing
    @testable import weft

    private func windowsPowerShell() -> URL {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return URL(fileURLWithPath: root).appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe")
    }

    private func spawnWindowsFixture(_ script: String, environment: [String: String]? = nil) throws
        -> PseudoTerminalProcess
    {
        // EncodedCommand avoids shell quoting ambiguity; input and output still traverse the real ConPTY.
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
        return try PseudoTerminalProcess(
            executable: windowsPowerShell(),
            arguments: ["-NoLogo", "-NoProfile", "-EncodedCommand", encoded], environment: environment)
    }

    private func drainWindowsFixture(_ child: PseudoTerminalProcess, timeout: TimeInterval = 15) throws -> (
        String, Int32?
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var status: Int32?
        var eof = false
        while Date() < deadline && !(eof && status != nil) {
            if !eof {
                if let packet = try child.read(timeoutMilliseconds: 50) { output.append(packet) } else { eof = true }
            }
            status = try child.pollExitStatus()
            if eof && status == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(eof, "ConPTY final output must reach EOF within the fixture deadline")
        return (String(decoding: output, as: UTF8.self), status)
    }

    private func waitForWindowsReady(_ child: PseudoTerminalProcess) throws {
        let deadline = Date().addingTimeInterval(15)
        var output = Data()
        while Date() < deadline {
            guard let packet = try child.read(timeoutMilliseconds: 50) else { break }
            output.append(packet)
            if String(decoding: output, as: UTF8.self).contains("WEFT-READY") { return }
        }
        Issue.record("ConPTY fixture did not finish initialization")
    }

    @Test func windowsConPTYProducesOutputAndNativeExitStatus() throws {
        let child = try spawnWindowsFixture("[Console]::WriteLine('WEFT-OUTPUT'); exit 7")
        defer { child.close() }
        let (output, status) = try drainWindowsFixture(child)
        #expect(output.contains("WEFT-OUTPUT"))
        #expect(status == 7)
    }

    @Test func windowsConPTYConnectsAllStandardHandlesToItsConsole() throws {
        // `swift test` in CI has redirected reporter pipes. The child must receive new
        // console handles instead of duplicated copies of those parent pipes.
        let child = try spawnWindowsFixture(
            "[Console]::WriteLine('CONPTY-HANDLES:' + [Console]::IsInputRedirected + ':' + [Console]::IsOutputRedirected + ':' + [Console]::IsErrorRedirected); [Console]::Error.WriteLine('CONPTY-STDERR'); exit 0"
        )
        defer { child.close() }
        let (output, status) = try drainWindowsFixture(child)
        #expect(output.contains("CONPTY-HANDLES:False:False:False"))
        #expect(output.contains("CONPTY-STDERR"))
        #expect(status == 0)
    }

    @Test func windowsConPTYAcceptsInputAndResizes() throws {
        let child = try spawnWindowsFixture(
            "$s = [Console]::ReadLine(); [Console]::WriteLine('RECEIVED:' + $s); exit 0")
        defer { child.close() }
        try child.resize(Rect(width: 100, height: 30))
        var input = Data("hello-conpty\r\n".utf8)
        let deadline = Date().addingTimeInterval(10)
        while !input.isEmpty && Date() < deadline {
            let count = try child.write(input)
            input.removeFirst(count)
            if count == 0 { _ = try child.waitForWritable(timeoutMilliseconds: 50) }
        }
        #expect(input.isEmpty)
        let (output, status) = try drainWindowsFixture(child)
        #expect(output.contains("RECEIVED:hello-conpty"))
        #expect(status == 0)
    }

    @Test func windowsConPTYEnvironmentAndUnicodeAreLiteral() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["WEFT_LITERAL_TEST"] = "spaces \"quotes\" \\ 界"
        let child = try spawnWindowsFixture(
            "[Console]::OutputEncoding = [Text.Encoding]::UTF8; [Console]::WriteLine($env:WEFT_LITERAL_TEST)",
            environment: environment)
        defer { child.close() }
        let (output, status) = try drainWindowsFixture(child)
        #expect(output.contains("spaces \"quotes\" \\ 界"))
        #expect(status == 0)
    }

    @Test func windowsConPTYCancellationTerminatesOwnedProcess() throws {
        let child = try spawnWindowsFixture("[Console]::WriteLine('WEFT-READY'); Start-Sleep -Seconds 60")
        defer { child.close() }
        try waitForWindowsReady(child)
        try child.terminate(signal: 9)
        let (_, status) = try drainWindowsFixture(child)
        #expect(status == 137)
        child.close()
        child.close()
        #expect(throws: TerminalError.sessionClosed) { try child.read() }
    }

    @Test func windowsConPTYRejectsNULArgumentsAndUnsupportedSignals() throws {
        #expect(throws: TerminalError.configurationFailed(operation: "child arguments", code: 87)) {
            try PseudoTerminalProcess(executable: windowsPowerShell(), arguments: ["bad\0argument"])
        }
        let child = try spawnWindowsFixture("[Console]::WriteLine('WEFT-READY'); Start-Sleep -Seconds 60")
        defer { child.close() }
        try waitForWindowsReady(child)
        #expect(throws: TerminalError.unsupportedOperation(operation: "POSIX child signals other than 15 or 9")) {
            try child.terminate(signal: 2)
        }
    }
    @Test func windowsConPTYArgumentsPreserveSpacesQuotesAndTrailingBackslashes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("literal arguments.ps1")
        try "foreach ($a in $args) { [Console]::WriteLine('ARG:' + $a) }".write(
            to: script, atomically: true, encoding: .utf8)
        let arguments = ["two words", "a\"b", "trailing\\", ""]
        let child = try PseudoTerminalProcess(
            executable: windowsPowerShell(),
            arguments: ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script.path] + arguments)
        defer { child.close() }
        let (output, status) = try drainWindowsFixture(child)
        #expect(output.contains("ARG:two words"))
        #expect(output.contains("ARG:a\"b"))
        #expect(output.contains("ARG:trailing\\"))
        #expect(status == 0)
    }

    @Test func windowsConPTYDrainsFinalOutputBeyondQueueCapacity() throws {
        let child = try spawnWindowsFixture(
            "$line = 'X' * 100; for ($i = 0; $i -lt 11000; $i++) { [Console]::WriteLine($line) }; [Console]::WriteLine('WEFT-FINAL'); exit 3"
        )
        defer { child.close() }
        let (output, status) = try drainWindowsFixture(child, timeout: 45)
        #expect(output.contains("WEFT-FINAL"))
        #expect(status == 3)
    }

    @Test func windowsConPTYCloseIsNonblockingWithBackpressuredOutput() throws {
        let child = try spawnWindowsFixture(
            "[Console]::WriteLine('WEFT-READY'); $deadline = [DateTime]::UtcNow.AddSeconds(10); while ([DateTime]::UtcNow -lt $deadline) { [Console]::WriteLine(('Y' * 1000)) }"
        )
        try waitForWindowsReady(child)
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        child.close()
        #expect(Date().timeIntervalSince(started) < 1)
    }
    @Test func windowsConPTYCancellationKillsGrandchildrenInOwnedJob() throws {
        let child = try spawnWindowsFixture(
            "$p = Start-Process powershell.exe -PassThru -ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 60'; [Console]::WriteLine('CHILD:' + $p.Id + ':END'); Start-Sleep -Seconds 60"
        )
        defer { child.close() }
        var output = Data()
        let deadline = Date().addingTimeInterval(15)
        var descendant: Int?
        while Date() < deadline && descendant == nil {
            guard let packet = try child.read(timeoutMilliseconds: 50) else { break }
            output.append(packet)
            let text = String(decoding: output, as: UTF8.self)
            if let range = text.range(of: "CHILD:[0-9]+:END", options: .regularExpression) {
                descendant = Int(text[range].dropFirst(6).dropLast(4))
            }
        }
        guard let descendant else {
            Issue.record("Grandchild PID was not emitted")
            return
        }
        try child.terminate(signal: 9)
        let (_, status) = try drainWindowsFixture(child)
        #expect(status == 137)
        let probe = try spawnWindowsFixture(
            "for ($i=0; $i -lt 50; $i++) { if (-not (Get-Process -Id \(descendant) -ErrorAction SilentlyContinue)) { exit 0 }; Start-Sleep -Milliseconds 100 }; exit 9"
        )
        defer { probe.close() }
        #expect(try drainWindowsFixture(probe).1 == 0)
    }
#endif
