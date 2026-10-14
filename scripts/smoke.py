#!/usr/bin/env python3
"""Verify a demo starts, accepts input, resizes, and restores its PTY."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

master, slave = pty.openpty()
original = termios.tcgetattr(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
escape_timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 35
arguments = [sys.argv[1]]
if len(sys.argv) > 2:
    arguments += ['--escape-timeout-ms', str(escape_timeout)]
process = subprocess.Popen(arguments, stdin=slave, stdout=slave, stderr=slave)
output = bytearray()

def read_until(token, timeout=10):
    deadline = time.monotonic() + timeout
    while token not in output and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            output.extend(os.read(master, 65536))
        if process.poll() is not None:
            break
    assert token in output, (token, bytes(output[-2000:]))

try:
    read_until(b'\x1b[?1049h')
    read_until(b'exits.')
    read_until(b'\x1b[?1004h')
    os.write(master, b'\x1b[O\x1b[I')
    read_until(b'focusChanged(false)')
    read_until(b'focusChanged(true)')
    os.write(master, b'z')
    read_until(b'z')
    os.write(master, b'\x1b[57414u\x1bOq')
    read_until(b'key: weft.Key.enter')
    read_until(b'text("1")')
    if escape_timeout >= 150:
        os.write(master, b'\x1b')
        time.sleep(0.06)
        assert process.poll() is None, 'Escape timeout ignored while waiting for a fragmented key'
        os.write(master, b'[57407u')
        read_until(b'text("8")')
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    read_until(b'resize(100, 30)')
    escape_sent = time.monotonic()
    os.write(master, b'\x1b')
    read_until(b'\x1b[?1049l')
    elapsed = time.monotonic() - escape_sent
    assert elapsed >= max(0, escape_timeout / 1000 - 0.015), ('Escape resolved too early', elapsed)
    process.wait(timeout=10)
    while select.select([master], [], [], 0)[0]:
        output.extend(os.read(master, 65536))
    assert process.returncode == 0, bytes(output[-2000:])
    assert b'\x1b[?1049l' in output, 'alternate screen was not restored'
    assert b'\x1b[?1004l' in output, 'focus reporting was not restored'
    assert termios.tcgetattr(slave) == original, 'terminal settings were not restored'
    print(f'PTY smoke passed: startup, focus reports, keypad, input, resize, Escape ({escape_timeout} ms), restoration')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
