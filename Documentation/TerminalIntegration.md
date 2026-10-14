# Terminal integration

Use `TerminalSession` on one serial execution context. If `TerminalEvents` is
attached, create the source, consume it, and call session methods on the main
actor. An attached source owns decoded input; synchronous polling rejects a
second reader.

## Mouse events

Opt into capture with `TerminalOptions(mouseCapture: true)`. `MouseEvent` carries
zero-based cell coordinates, a `kind`, a `button`, and `modifiers`. Buttons include
left, middle, right, and `.additional(8...11)`. Hover and scrolling have no button.
Wheel kinds cover up, down, left, and right. Shift, Alt, and Control modifiers are
preserved on press, release, drag, hover, and scroll reports.

`setMouseEnabled(true, reportMotion: true)` enables unpressed motion. Capture otherwise
reports clicks and drags. Selection, dragging, scrolling, and shortcut policies
belong to the application; the decoder only describes input. Unsupported or
malformed reports are discarded. Existing `MouseEvent(kind:position:)` calls continue
to default press/drag/release to the left button.

## Typed terminal queries

```swift
let request = try session.requestQuery(.backgroundColor, timeoutMilliseconds: 250)
for try await batch in input.events {
    for event in batch {
        if case let .queryResult(result) = event, result.id == request {
            switch result.outcome {
            case let .reply(.backgroundColor(rgb)):
                print("Background:", rgb) // UInt16 channels, normalized to 0...65535
            case .timedOut, .cancelled:
                break // Keep the application's fallback.
            default:
                break
            }
        }
    }
}
```

Create `input` as `TerminalEvents(session: session)` before this code, on the main
actor. In a synchronous application, consume the same results with `poll()`.
The query selects decoded input only when it is successfully sent. It cannot
share a session with raw-byte polling.

Available queries are cursor position, foreground/background RGB colors, Kitty
keyboard support and active flags, light/dark color scheme, and DEC private-mode
status. Cursor positions are zero-based cells. Kitty detection uses a device
attributes response as its unsupported fallback. For example, a reset DECRPM
status still confirms that a mode is available; it is merely off.

Requests return IDs local to weft. There can be one pending request per query and
at most 32 pending requests plus unconsumed cancellation/timeout completions.
`cancelQuery(id)` completes a pending request as `.cancelled`. Zero timeout expires
immediately. Timeouts are bounded even for indefinite polling and fire through
`TerminalEvents` without waiting for another keystroke.

Terminal protocols have no request IDs on the wire. Unmatched reports are ignored,
but a very late response can match a retry of the same query. Consume completions
and allow late replies to drain before retrying. A timeout leaves support unknown;
keep a fallback. Apply confirmed replies to a profile with
`TerminalCapabilities.apply(_:)` when the application wants to refine its
initial environment inference. The session does not change application policy.

For live light/dark changes, opt into
`TerminalOptions(colorSchemeReporting: true)`. Unsolicited recognized notifications
arrive as `.terminalReply(.colorScheme(...))`. A `.colorScheme` query also works
without a subscription. Reporting is disabled during handoff and on close.
Unsupported terminals may never reply or report changes.

Standalone `InputDecoder()` continues to suppress terminal replies. Pass
`terminalReplies: true` to receive recognized `.terminalReply` values and manage
correlation yourself. Parsing is incremental and bounded; replies inside
bracketed paste remain literal text.

## Terminal handoff and shell suspension

```swift
try session.withSuspendedTerminal {
    // Launch and wait for your editor or pager here, inheriting stdin/out/err.
    try runEditorAndWait()
}
// Redraw when the reader delivers .terminalResumed.
```

The closure is synchronous and must finish before returning. Command selection,
process creation, and waiting belong to the application. The session pauses its
async reader, cancels pending queries, discards partial decoded input, releases
its ANSI modes, and restores POSIX settings and prior signal handlers. After the
closure succeeds or throws, it reacquires input and restores session options,
including dynamically enabled mouse motion. It does not repeat explicit screen
or scrollback clearing. Resume delivers `.terminalResumed` through both decoded
and byte readers; applications choose how to refresh their screen.

For explicit ownership transitions, use `suspend()` and `resume()`. Both are
idempotent in their corresponding state. Input/output calls throw
`.sessionSuspended` while released. If suspension's ANSI write fails, POSIX
ownership is still released; the handoff closure is not run. If resume fails, the
session stays suspended and may be retried. If both the closure and resume fail,
`TerminalHandoffError` retains both errors. Closing a suspended session leaves the
terminal alone and finishes its async stream.

Call `suspendToShell()` in response to the application's Ctrl-Z command or
`.signal(SIGTSTP)`. It releases ownership, sends SIGTSTP to the process with the prior disposition,
and resumes when the shell continues the job with `fg`. A shell with job control
and a foreground process group is needed for an actual stop; previously ignored
or custom SIGTSTP handlers retain their behavior. No application command is
chosen automatically. `weft-demo --features` exercises both handoff and shell
suspension.

## Validation and protocol references

Unit tests cover fragmented/malformed reports, literal paste, matching and
bounded queries, timeouts, input ownership, and handoff failure paths. PTY smoke
checks emulate terminal query responses, then verify canonical child input,
repeated handoffs, input resumption, and termios/mode restoration. A separate
interactive shell on a controlling PTY checks real Ctrl-Z/`fg` job control. These
checks do not establish support across all terminal emulators or SSH/tmux setups.

Protocol definitions: [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html),
[Kitty support detection](https://sw.kovidgoyal.net/kitty/keyboard-protocol/#detection-of-support-for-this-protocol),
and [Contour color-scheme notifications](https://contour-terminal.org/vt-extensions/color-palette-update-notifications/).
