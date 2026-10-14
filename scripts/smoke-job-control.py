#!/usr/bin/env python3
"""Exercise actual shell job control with a controlling terminal and foreground job."""
import errno
import os
import pty
import select
import shlex
import signal
import sys
import termios
import time

executable = os.path.abspath(sys.argv[1])
shell_pid, master = pty.fork()
if shell_pid == 0:
    os.environ['PS1'] = 'weft-shell> '
    os.execv('/bin/sh', ['sh', '-i'])
os.set_blocking(master, False)
output = bytearray()

def read_until(token, start=0, timeout=10):
    deadline = time.monotonic() + timeout
    while token not in output[start:] and time.monotonic() < deadline:
        if select.select([master], [], [], 0.05)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                raise
    assert token in output[start:], (token, bytes(output[-4000:]))

try:
    read_until(b'weft-shell> ')
    original = termios.tcgetattr(master)
    start = len(output)
    os.write(master, (shlex.quote(executable) + ' --features\n').encode())
    read_until(b'Ctrl-E runs a handoff', start)
    for _ in range(2):
        start = len(output)
        os.write(master, b'\x1a')
        read_until(b'weft-shell> ', start)
        assert b'\x1b[?1049l' in output[start:], 'stopped job retained alternate screen'
        assert termios.tcgetattr(master) == original, 'stopped job retained raw terminal settings'
        start = len(output)
        os.write(master, b'fg\n')
        read_until(b'terminalResumed', start)
        assert b'\x1b[?1049h' in output[start:], 'continued job did not restore alternate screen'
        assert termios.tcgetattr(master) != original, 'continued job did not restore raw input'
        os.write(master, b'x')
        read_until(b'text("x")', start)
    start = len(output)
    os.write(master, b'\x1b')
    read_until(b'weft-shell> ', start)
    assert termios.tcgetattr(master) == original, 'exited job did not restore terminal settings'
    assert output.count(b'\x1b[>31u') == output.count(b'\x1b[<u'), 'unbalanced keyboard stack'
    os.write(master, b'exit\n')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        # Darwin's tty close can wait for queued shell output to drain.
        if select.select([master], [], [], 0.02)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError as error:
                if error.errno not in (errno.EIO, errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
        child, status = os.waitpid(shell_pid, os.WNOHANG)
        if child:
            shell_pid = None
            assert os.waitstatus_to_exitcode(status) == 0
            break
        time.sleep(0.02)
    assert shell_pid is None, 'shell did not exit'
    print('Job-control PTY smoke passed: repeated Ctrl-Z, shell ownership, fg, async resume, cleanup')
finally:
    if shell_pid is not None:
        foreground = os.tcgetpgrp(master)
        if foreground > 0 and foreground != shell_pid:
            try:
                os.killpg(foreground, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.kill(shell_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # Close the PTY before reaping: Darwin can delay process exit while the
        # terminal is still attached. Cleanup must also remain bounded on failure.
        os.close(master)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if os.waitpid(shell_pid, os.WNOHANG)[0]:
                break
            time.sleep(0.02)
    else:
        os.close(master)
