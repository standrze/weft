#!/usr/bin/env python3
"""Exercise query replies, mouse input, handoff, and restored async input on a PTY."""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

master, slave = pty.openpty()
original = termios.tcgetattr(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
process = subprocess.Popen([sys.argv[1], '--features'], stdin=slave, stdout=slave, stderr=slave)
output = bytearray()

def read_until(token, start=0, timeout=10):
    deadline = time.monotonic() + timeout
    while token not in output[start:] and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            output.extend(os.read(master, 65536))
        if process.poll() is not None:
            break
    assert token in output[start:], (token, bytes(output[-4000:]))

try:
    read_until(b'\x1b[?996n')
    read_until(b'Ctrl-E runs a handoff')
    os.write(master, b'\x1b[5;7R\x1b]10;rgb:ffff/0000/0000\x07')
    os.write(master, b'\x1b]11;rgb:0000/0000/0000\x1b\\\x1b[?31u\x1b[?1;2c')
    os.write(master, b'\x1b[?2026;2$y\x1b[?2031;2$y\x1b[?997;1n')
    read_until(b'cursorPosition(weft.Point(x: 6, y: 4))')
    read_until(b'foregroundColor(weft.TerminalRGB(red: 65535, green: 0, blue: 0))')
    read_until(b'backgroundColor(weft.TerminalRGB(red: 0, green: 0, blue: 0))')
    read_until(b'kittyKeyboard(flags: 31)')
    read_until(b'privateMode(2026, weft.TerminalModeState.reset)')
    read_until(b'privateMode(2031, weft.TerminalModeState.reset)')
    read_until(b'colorScheme(weft.TerminalColorScheme.dark)')
    os.write(master, b'\x1b[<30;3;4M\x1b[<66;3;4M\x1b[?997;2n')
    read_until(b'weft.MouseButton.right')
    read_until(b'weft.MouseKind.wheelLeft')
    read_until(b'colorScheme(weft.TerminalColorScheme.light)')
    for _ in range(2):
        start = len(output)
        os.write(master, b'\x05')
        read_until(b'handoff-ready', start)
        assert termios.tcgetattr(slave) == original, 'handoff did not restore normal terminal settings'
        assert b'\x1b[?1049l' in output[start:], 'handoff did not release alternate screen'
        assert b'\x1b[?2031l' in output[start:], 'handoff did not release theme notifications'
        os.write(master, b'canonical input\n')
        read_until(b'handoff-input:canonical input', start)
        read_until(b'handoff-complete', start)
        read_until(b'terminalResumed', start)
        assert termios.tcgetattr(slave) != original, 'resume did not reacquire raw input'
        assert b'\x1b[?1049h' in output[start:], 'resume did not enter alternate screen'
        os.write(master, b'x')
        read_until(b'text("x")', start)
    start = len(output)
    os.write(master, b'\x1b')
    read_until(b'\x1b[?1049l', start)
    process.wait(timeout=10)
    while select.select([master], [], [], 0)[0]:
        output.extend(os.read(master, 65536))
    assert process.returncode == 0, bytes(output[-4000:])
    assert termios.tcgetattr(slave) == original, 'terminal settings were not restored on exit'
    assert output.count(b'\x1b[>31u') == output.count(b'\x1b[<u'), 'unbalanced keyboard stack'
    assert output.count(b'\x1b[?2031h') == output.count(b'\x1b[?2031l'), 'unbalanced theme notifications'
    print('Feature PTY smoke passed: typed queries, theme updates, mouse, repeated handoff, async resume, cleanup')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
