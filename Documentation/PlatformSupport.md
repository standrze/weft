# Platform support and Unicode geometry

weft keeps one terminal input reader and explicit session ownership. loom owns
rendering and widgets. No application event-routing policy moves into weft.

## Unicode cell widths

`terminalCellWidth` no longer calls libc `wcwidth` or changes process locale.
Combining marks, default-ignorable scalars and controls contribute zero cells;
East Asian Wide/Fullwidth scalars use two cells and ambiguous-width scalars use
one. Emoji presentation, variation selectors, keycaps and grapheme clusters
receive explicit handling. The committed Unicode 17 width table records its
source and accompanies the Unicode data license.

This corrects Linux C-locale failures that counted combining marks as additional
printable cells. Terminals/fonts can still disagree with an estimate; loom text
layout accepts a custom measure function. CI runs C and C.UTF-8 test processes.

## Native Windows consoles

Entry saves input/output modes and code pages, enables raw console input and VT
output, and restores settings after failure, handoff, or close. `ReadConsoleInputW`
is the only reader. Native key records (including surrogate pairs/modifiers),
mouse and focus records become UTF-8/VT for the existing decoder; viewport size
supplies resize events. Cancellable native waits and main-queue acknowledgments
provide asynchronous readiness without an idle polling timer or second reader.

Windows `pollBytes` returns reconstructed UTF-8/VT, not an original byte transport.
Native records do not expose original bracketed-paste frames or Kitty key phases.
Console sessions require `rawMode: true`; canonical mode throws
`unsupportedOperation` before mode changes. Use `withSuspendedTerminal` for
editor/pager handoff. POSIX `suspendToShell` is explicitly unsupported on Windows
and leaves ownership unchanged. Windows close/shutdown deadlines and forced
termination can prevent restoration, as with forced termination on POSIX.

## Native Windows child terminals

`PseudoTerminalProcess` uses ConPTY on Windows 10 1809+/Server 2019+, preserving
its public read/write/resize/status/close APIs. `CreateProcessW` receives literal
UTF-16 arguments and environment values. Separate bounded queues serve input
and output; a Job Object owns the process tree. ConPTY output is preserved as
pseudoconsole bytes; ConPTY itself renders/normalizes the child's console output.

Output draining continues while `ClosePseudoConsole` flushes its final frame.
`close` schedules teardown off the caller's context and terminates the owned tree.
Exit status can precede final output EOF. DWORD process IDs and exit codes retain
their bits in existing Int32 properties. Signals 15/9 force Job Object termination
with status 128+signal; other POSIX signals throw `unsupportedOperation`.
Working directory remains inherited, preserving the existing API.

Win32 calls are confined to CWeft helpers following Microsoft's
[console record input](https://learn.microsoft.com/en-us/windows/console/readconsoleinput)
and [ConPTY lifecycle](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session)
contracts, including draining concurrently with pseudoconsole closure.

## Validation

CI pins Swift 6.4.1 on macOS/Windows and the official Linux container. A standalone
weft pass does not establish correctness for loom's combined layout stack.

Local pre-CI validation on 2026-10-18:

| Environment | Evidence |
| --- | --- |
| macOS arm64 Swift 6.4 | 65 weft tests; standard/features/job-control PTYs passed |
| Linux arm64 Swift 6.4.1 C locale | 65 weft tests and 283 loom tests passed |
| Linux arm64 Swift 6.4.1 C.UTF-8 locale | 65 weft tests and 283 loom tests passed |
| Linux lifecycle | Standard/extended Escape, features, job control, and all four loom PTYs passed |

Windows tests cover private-console restoration, Unicode/key input, resize,
async readiness, interrupts, and ConPTY input/output, literal arguments/env,
exit status, final-output draining, and process-tree cleanup.
`scripts/smoke-windows.ps1` runs console tests in a separate process allocating
its own private console. Hosted Windows results are required before claiming
verified support. A workflow configuration alone is not a passing result.
