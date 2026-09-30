# Terminal ownership

```text
application → weft → Swift System / operating system terminal APIs
```

`TerminalSession` owns raw mode and signal handlers. Only one session may be open
in a process. Use one serial execution context and call `close()` when finished.
Initialization failures restore terminal settings; `close()` is idempotent.
SIGKILL cannot run cleanup. ANSI modes return to conventional defaults rather than
queried prior values. Clearing scrollback is explicit and irreversible.

`TerminalEvents` delivers batches through an `AsyncThrowingStream` on the main
actor, driven by file descriptor readiness and signal notifications. It uses a
short timeout only to disambiguate a pending Escape byte. Do not call `poll()`
while the event source is active. Stop the event source before closing the session.

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
