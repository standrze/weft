import Foundation
import weft

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@main
struct Demo {
    @MainActor
    static func main() async throws {
        var options = TerminalOptions(alternateScreen: true, focusReporting: true)
        let arguments = Array(CommandLine.arguments.dropFirst())
        var features = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--features":
                features = true
                index += 1
            case "--escape-timeout-ms":
                guard index + 1 < arguments.count, let timeout = Int(arguments[index + 1]), timeout >= 0 else {
                    throw DemoError.invalidArguments
                }
                options.escapeTimeoutMilliseconds = timeout
                index += 2
            default: throw DemoError.invalidArguments
            }
        }
        if features {
            options.mouseCapture = true
            options.keyboardProtocol = .kitty
            options.colorSchemeReporting = true
        }
        let session = try TerminalSession(options: options)
        defer { session.close() }
        let input = TerminalEvents(session: session)
        defer { input.stop() }
        var output = ANSIBackend()
        try output.write(Data("weft / the terminal, untangled.\r\nPress keys. Escape or Ctrl-C exits.\r\n".utf8))
        if features {
            for query: TerminalQuery in [
                .cursorPosition, .foregroundColor, .backgroundColor, .kittyKeyboard,
                .privateMode(2026), .privateMode(2031), .colorScheme,
            ] {
                try session.requestQuery(query, timeoutMilliseconds: 1000)
            }
            try output.write(Data("Ctrl-E runs a handoff; Ctrl-Z suspends to your shell.\r\n".utf8))
        }

        for try await batch in input.events {
            for event in batch {
                if let keyboard = event.keyboardEvent, keyboard.modifiers.contains(.control) {
                    if features && keyboard.key == .character("e") {
                        try session.withSuspendedTerminal { try runHandoffExample() }
                        try output.write(Data("handoff-complete\r\n".utf8))
                        continue
                    }
                    if keyboard.key == .character("z") {
                        #if !os(Windows)
                            try session.suspendToShell()
                        #endif
                        continue
                    }
                }
                if let key = event.keyboardEvent?.key, [.escape, .interrupt, .endOfInput].contains(key) {
                    return
                }
                if case let .signal(number) = event {
                    #if !os(Windows)
                        if number == Int(SIGTSTP) {
                            try session.suspendToShell()
                            continue
                        }
                    #endif
                    return
                }
                try output.write(Data("\(String(reflecting: event))\r\n".utf8))
            }
        }
    }

    private static func runHandoffExample() throws {
        let process = Process()
        #if os(Windows)
            let command = ProcessInfo.processInfo.environment["ComSpec"] ?? "C:/Windows/System32/cmd.exe"
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = ["/d", "/c", "echo handoff-ready & set /p WEFT_HANDOFF_LINE= & echo handoff-complete"]
        #else
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c", #"printf 'handoff-ready\n'; IFS= read -r line; printf 'handoff-input:%s\n' "$line""#,
            ]
        #endif
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DemoError.handoffFailed(process.terminationStatus) }
    }
}

private enum DemoError: Error {
    case invalidArguments
    case handoffFailed(Int32)
}
