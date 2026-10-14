# Terminal ownership

```text
application → weft → Swift System / operating system terminal APIs
```

`TerminalSession` owns raw mode and signal handlers. Only one session may own the terminal
in a process. Use one serial execution context and call `close()` when finished.
Initialization failures restore terminal settings; `close()` is idempotent.
SIGKILL cannot run cleanup. ANSI modes return to conventional defaults rather than
queried prior values. Clearing scrollback is explicit and irreversible.

`TerminalEvents` delivers batches through an `AsyncThrowingStream` on the main
actor, driven by file descriptor readiness and signal notifications. It uses a
deadline task only for pending Escape bytes or terminal queries. Keep the session
on the main actor while this source is attached. Only one source may attach;
`poll()` and `pollBytes()` reject calls while it owns input. Closing the session
stops its source, and `stop()` releases the reader reservation.

Suspension pauses readiness observers and query deadlines before releasing ANSI
modes, POSIX settings, and signal handlers. Resume reacquires those resources
and delivers `.terminalResumed`; the application decides how to redraw. Partial
decoded input is discarded and pending queries complete as cancelled after resume.
Closing a suspended session does not change a terminal now owned by another caller.

Typed replies share the decoded reader with keys, mouse events, and paste. A
bounded query queue matches known reports to requests, and unrecognized or late
replies are discarded. Timeouts do not imply lack of support. Color-scheme
notifications are opt-in. See [terminal integration](TerminalIntegration.md).

`InputDecoder` owns no file descriptors. Feed it bytes from any source; fragmented
UTF-8, escape sequences, and bracketed pastes may span calls. `Backend` accepts
output data; `ANSIBackend` writes it to the terminal. `Reed.swift` contains the
POSIX implementation, using Swift System for file descriptors.

`Point`, `Rect`, and character widths use terminal cells. Cell width can vary by
terminal and font. A Unicode grapheme does not necessarily occupy one cell.

Defaults preserve the primary screen, scrollback, visible cursor, and native
mouse selection. Alternate screens, mouse capture, and Kitty keyboard encoding
are application choices. Platform paths exist for Darwin and Glibc; Windows is
not supported by the current POSIX implementation.
