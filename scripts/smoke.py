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
process = subprocess.Popen([sys.argv[1]], stdin=slave, stdout=slave, stderr=slave)
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
    os.write(master, b'z')
    read_until(b'z')
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    os.write(master, b'\x1b')
    read_until(b'\x1b[?1049l')
    process.wait(timeout=10)
    while select.select([master], [], [], 0)[0]:
        output.extend(os.read(master, 65536))
    assert process.returncode == 0, bytes(output[-2000:])
    assert b'\x1b[?1049l' in output, 'alternate screen was not restored'
    assert termios.tcgetattr(slave) == original, 'terminal settings were not restored'
    print('PTY smoke passed: startup, input, resize, Escape, mode restoration')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
