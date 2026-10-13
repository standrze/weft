# Cursor-position queries

`TerminalSession.requestCursorPosition(timeoutMilliseconds:)` sends ANSI DSR 6
through the session output driver and returns a UUID. At most one query may be
pending; a second request throws `cursorPositionQueryAlreadyPending`. Durations
are clamped to 1...60,000 milliseconds and measured with monotonic uptime.

Consume `InputEvent.cursorPositionQuery(result)` through the same `poll` or
`TerminalEvents.events` path that receives keyboard and resize events. A result
contains the original ID and `.position(Point)`, `.timedOut`, or `.cancelled`.
Positions use zero-based physical terminal coordinates. No second input reader
is created. Synchronous `poll` bounds its requested wait by the query deadline;
`TerminalEvents` adds a deadline task so an unsupported terminal still completes
without keyboard activity.

`cancelCursorPositionQuery(id:)` cancels only a matching query and returns whether
it did so. Its completion is queued for the next synchronous poll, or delivered
to an active `TerminalEvents` source. Close cancels pending query state; an active
event source receives that completion, while synchronous callers should cancel
and poll before closing if they need the cancellation result. As before, closed
sessions reject polling. A query output failure throws and leaves no pending ID;
do not assume a failed output wrote zero bytes.

The decoder accepts only a positive decimal `row;column` CPR ending in CSI R.
Fragmentation is supported. Unsolicited and malformed reports never become text
or F3 keystrokes. SS3 F3 and extended tilde F3 remain keyboard events. Coordinates
are advisory: DSR responses have no request token, so a late reply cannot be
correlated against a later query. Avoid using a cursor result as authorization or
as proof that output completed. Application code owns anchor acceptance, resize
handling, and viewport policy.

Run the ordinary format, test, and demo checks, then:

```sh
python3 scripts/smoke-cursor.py .build/debug/weft-demo
```

That fixture supplies fragmented CPR through a PTY, interleaves input and resize,
and checks timeout with no input plus terminal-mode restoration. It proves the
single-reader transport behavior, not an emulator's cursor reporting accuracy.
