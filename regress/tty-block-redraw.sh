#!/bin/sh

# The per-client output block exists so that a fast pane cannot make tmux sit
# on a huge buffer of data for a terminal that is slow to accept it. A client
# is exempted from that check while a redraw it was sent is still being
# written out, on the assumption that a redraw drains promptly - which is not
# true of a terminal reading at a few kilobytes a second, where one screen
# takes seconds. For as long as the exemption holds nothing bounds the buffer
# at all, so what the terminal is shown is however many megabytes were queued
# ahead of it.
#
# A pane paints truecolor screens continuously while the terminal is read at
# roughly 10 KB/s. What tmux has queued but not delivered must stay bounded,
# and the terminal must still be shown the current screen.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

python3 - "$TEST_TMUX" <<'PY'
import os
import select
import signal
import subprocess
import sys
import tempfile
import time

tmux = sys.argv[1]
label = "test-block-redraw-%d" % os.getpid()
server = [tmux, "-L" + label, "-f/dev/null"]

WIDTH, HEIGHT = 80, 24
BLOCK_START = 1 + WIDTH * HEIGHT * 8
BACKLOG_BUDGET = 1000000
BACKLOG_TIMEOUT = 0.5
RUN_SECONDS = 8
SLOW_BYTES = 512
SLOW_INTERVAL = 0.05

EMITTER = """\
import os
import sys
import time

start = sys.argv[1]
marker = sys.argv[2]
while not os.path.exists(start):
    time.sleep(0.01)


def build(seed):
    top = b"MARKER" if os.path.exists(marker) else b"STALE"
    out = [b"\\033[H\\033[0m" + top]
    for index, row in enumerate(range(2, 25)):
        cells = [("\\033[%d;1H" % row).encode()]
        for column in range(70):
            cells.append(("\\033[38;2;%d;%d;%dm#" % (
                (seed * 7 + column * 3 + index * 11) % 256,
                (seed * 13 + column * 5 + index * 3) % 256,
                (seed * 3 + column * 11 + index * 7) % 256)).encode())
        out.append(b"".join(cells))
    return b"".join(out)


frames = [build(1), build(2)]
marked = False
while True:
    if not marked and os.path.exists(marker):
        frames = [build(3), build(4)]
        marked = True
    for frame in frames:
        os.write(1, frame)
"""


def run(*args, check=True):
    return subprocess.run(server + list(args), check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def attach():
    pid, fd = os.forkpty()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execl(tmux, tmux, "-L" + label, "-f/dev/null",
            "attach-session", "-t", "blocked")
    os.set_blocking(fd, False)
    return pid, fd


def read_ready(fd, size):
    readable, _, _ = select.select([fd], [], [], 0)
    if fd not in readable:
        return b""
    try:
        return os.read(fd, size)
    except (BlockingIOError, OSError):
        return b""


def counters():
    output = run("list-clients", "-F",
        "#{client_written} #{client_discarded}").stdout
    rows = [line.split() for line in output.splitlines()]
    values = [(int(row[0]), int(row[1])) for row in rows if len(row) == 2]
    return max(values, default=(0, 0))


def cleanup(pid=None, fd=None):
    if fd is not None:
        os.close(fd)
    if pid is not None:
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
    run("kill-server", check=False)


run("kill-server", check=False)
with tempfile.TemporaryDirectory() as directory:
    start = os.path.join(directory, "start")
    marker = os.path.join(directory, "marker")
    emitter = os.path.join(directory, "emitter.py")
    with open(emitter, "w", encoding="utf-8") as handle:
        handle.write(EMITTER)

    run("new-session", "-d", "-x", str(WIDTH), "-y", str(HEIGHT), "-s",
        "blocked", "python3 -u %s %s %s" % (emitter, start, marker))
    run("set-option", "-g", "status", "off")
    run("set-option", "-g", "window-size", "manual")
    run("set-option", "-as", "terminal-features", "*:RGB")

    pid, fd = attach()
    try:
        # The attach redraw is exempt from the block check until it drains, so
        # it is taken at full speed and everything measured afterwards is the
        # backlog built by pane output alone.
        settle = time.time() + 1
        while time.time() < settle:
            read_ready(fd, 1 << 20)
            time.sleep(0.01)
        base_written, base_discarded = counters()
        open(start, "w", encoding="utf-8").close()

        consumed = 0
        peak = 0
        excess_since = None
        longest_excess = 0
        overrun = False
        seen = False
        window = b""
        end = time.time() + RUN_SECONDS
        while time.time() < end:
            chunk = read_ready(fd, SLOW_BYTES)
            time.sleep(SLOW_INTERVAL)
            consumed += len(chunk)
            current_written, current_discarded = counters()
            backlog = (current_written - base_written -
                (current_discarded - base_discarded) - consumed)
            peak = max(peak, backlog)
            if backlog > BACKLOG_BUDGET:
                if excess_since is None:
                    excess_since = time.time()
                longest_excess = max(longest_excess,
                    time.time() - excess_since)
            else:
                excess_since = None
            if backlog > BLOCK_START:
                if not overrun:
                    open(marker, "w", encoding="utf-8").close()
                overrun = True
                window = b""
                continue
            if overrun:
                window = (window + chunk)[-8192:]
                if b"MARKER" in window:
                    seen = True

        if not overrun:
            raise RuntimeError("the terminal was never overrun, so no flow "
                "control was exercised: peak backlog %d bytes" % peak)
        if longest_excess > BACKLOG_TIMEOUT:
            raise RuntimeError("tmux sustained a backlog above %d bytes for "
                "%.2f seconds (peak %d, consumed %d)" % (BACKLOG_BUDGET,
                longest_excess, peak, consumed))
        if not seen:
            raise RuntimeError("terminal was never shown the current screen "
                "after the backlog was bounded: peak %d, consumed %d" %
                (peak, consumed))
    finally:
        cleanup(pid, fd)
PY
