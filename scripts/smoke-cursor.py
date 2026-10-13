#!/usr/bin/env python3
"""Exercise cursor query through the real PTY single-reader async path.

This supplies terminal replies; it does not verify a terminal emulator's CPR.
"""
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


def exercise(reply):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    process = subprocess.Popen([sys.argv[1], '--cursor-query'], stdin=slave, stdout=slave, stderr=slave)
    output = bytearray()

    def read_until(token, timeout=10):
        deadline = time.monotonic() + timeout
        while token not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                output.extend(os.read(master, 65536))
            if process.poll() is not None:
                break
        assert token in output, (token, bytes(output[-3000:]))

    try:
        read_until(b'\x1b[6n')
        if reply:
            os.write(master, b'x\x1b[12;')
            time.sleep(0.02)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            os.write(master, b'34Ry\x1b[13;2:3~')
            read_until(b'x: 33, y: 11')
            read_until(b'function(3)')
            read_until(b'resize(100, 30)')
        else:
            # No input wakes the source: its query deadline task must fire.
            read_until(b'timedOut')
        os.write(master, b'\x1b')
        read_until(b'\x1b[?1049l')
        process.wait(timeout=10)
        assert process.returncode == 0, bytes(output[-3000:])
        assert termios.tcgetattr(slave) == original, 'terminal settings were not restored'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


exercise(True)
exercise(False)
print('Cursor PTY smoke passed: fragments, keys, resize, idle timeout, mode restoration')
