#!/bin/sh

# A layout resize must notify synchronized applications before the pending
# geometry redraw is presented. Their first post-resize frames are collected in
# the backing screens and the client receives one final redraw, not a stale
# geometry frame followed by one correction per pane.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

python3 - "$TEST_TMUX" <<'PY'
import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


tmux = sys.argv[1]
label = "test-resize-sync-redraw-%d" % os.getpid()
server = [tmux, "-L" + label, "-f/dev/null"]
width = 100
height = 30
sync_start = b"\033[?2026h"
sync_end = b"\033[?2026l"
barrier_deadline = 0.15
release_quiet = barrier_deadline + 0.15

emitter_source = r'''
import os
import signal
import sys
import time


name, update_mode, ready, arm, resized, gate, painted, preopen, preopened = \
    sys.argv[1:]
pending = False
generation = 0


def touch(path):
    with open(path, "w", encoding="utf-8"):
        pass


def on_resize(_signum, _frame):
    global pending
    if os.path.exists(arm):
        pending = True


def paint(phase):
    size = os.get_terminal_size(1)
    rows = []
    for row in range(size.lines):
        marker = "%s_%s_%02d_" % (name, phase, row)
        fill = chr(ord("A") + (row * 7 + len(phase)) % 26)
        rows.append((marker + fill * size.columns)[:size.columns])
    start = "\033[?2026h" if update_mode == "sync" else ""
    end = "\033[?2026l" if update_mode == "sync" else ""
    payload = (start + "\033[H" + "\r\n".join(rows) + end).encode()
    written = os.write(1, payload)
    if written != len(payload):
        raise RuntimeError("short frame write")


def paint_open():
    size = os.get_terminal_size(1)
    marker = ("%s_OPEN_" % name).ljust(size.columns, "O")
    payload = ("\033[?2026h\033[H" + marker).encode()
    written = os.write(1, payload)
    if written != len(payload):
        raise RuntimeError("short open frame write")
    touch(preopened)


signal.signal(signal.SIGWINCH, on_resize)
os.write(1, b"\033[?1049h")
paint("BEFORE")
touch(ready)

while True:
    if os.path.exists(preopen):
        os.unlink(preopen)
        paint_open()
        continue
    if not pending:
        time.sleep(0.001)
        continue
    pending = False
    generation += 1
    touch(resized)
    while not os.path.exists(gate):
        time.sleep(0.001)
    paint("AFTER%d" % generation)
    touch(painted)
'''


def run(*args, check=True):
    return subprocess.run(
        server + list(args),
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def fail(message):
    raise RuntimeError(message)


def wait_for(predicate, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.005)
    fail(message)


def read_available(fd, duration):
    output = bytearray()
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.005)
        if fd not in readable:
            continue
        try:
            output.extend(os.read(fd, 1 << 20))
        except (BlockingIOError, OSError):
            break
    return bytes(output)


def drain_until_quiet(fd, quiet, timeout):
    output = bytearray()
    deadline = time.monotonic() + timeout
    quiet_deadline = time.monotonic() + quiet
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.005)
        if fd in readable:
            try:
                chunk = os.read(fd, 1 << 20)
            except (BlockingIOError, OSError):
                chunk = b""
            if chunk:
                output.extend(chunk)
                quiet_deadline = time.monotonic() + quiet
                continue
        if time.monotonic() >= quiet_deadline:
            return bytes(output)
    fail("client output did not become quiet")


def attach():
    pid, fd = os.forkpty()
    if pid == 0:
        fcntl.ioctl(
            1,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", height, width, 0, 0),
        )
        os.environ["TERM"] = "xterm-256color"
        os.execl(
            tmux,
            tmux,
            "-L" + label,
            "-f/dev/null",
            "attach-session",
            "-t",
            "resize",
        )
    os.set_blocking(fd, False)
    return pid, fd


def cleanup(pid=None, fd=None):
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    if pid is not None:
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
    run("kill-server", check=False)


run("kill-server", check=False)
with tempfile.TemporaryDirectory() as directory:
    emitter = os.path.join(directory, "emitter.py")
    with open(emitter, "w", encoding="utf-8") as handle:
        handle.write(emitter_source)

    paths = {}
    for name in ("LEFT", "RIGHT"):
        paths[name] = {
            key: os.path.join(directory, "%s-%s" % (name.lower(), key))
            for key in ("ready", "arm", "resized", "gate", "painted",
                "preopen", "preopened")
        }

    def command(name, synchronized=True):
        pane = paths[name]
        values = [
            name,
            "sync" if synchronized else "plain",
            pane["ready"],
            pane["arm"],
            pane["resized"],
            pane["gate"],
            pane["painted"],
            pane["preopen"],
            pane["preopened"],
        ]
        return "python3 -u %s %s" % (emitter, " ".join(values))

    run(
        "new-session",
        "-d",
        "-s",
        "resize",
        "-x",
        str(width),
        "-y",
        str(height),
        command("LEFT"),
    )
    left = run("display-message", "-p", "#{pane_id}").stdout.decode().strip()
    right = run(
        "split-window",
        "-d",
        "-h",
        "-t",
        left,
        "-PF",
        "#{pane_id}",
        command("RIGHT"),
    ).stdout.decode().strip()
    run("set-option", "-g", "status", "off")
    run("set-option", "-g", "set-titles", "off")
    run("set-option", "-g", "window-size", "manual")
    run("set-option", "-g", "automatic-rename", "off")
    run("set-option", "-as", "terminal-features", "*:sync")

    pid = None
    fd = None
    try:
        wait_for(
            lambda: all(os.path.exists(paths[name]["ready"])
                for name in paths),
            5,
            "synchronized applications did not become ready",
        )
        wait_for(
            lambda: b"LEFT_BEFORE_00_" in run(
                "capture-pane", "-p", "-t", left
            ).stdout and b"RIGHT_BEFORE_00_" in run(
                "capture-pane", "-p", "-t", right
            ).stdout,
            5,
            "initial synchronized frames did not reach both backing screens",
        )

        pid, fd = attach()
        wait_for(
            lambda: b"sync" in run(
                "list-clients", "-F", "#{client_termfeatures}"
            ).stdout,
            5,
            "sync-capable client did not attach",
        )
        client_size = run(
            "list-clients", "-F", "#{client_width}x#{client_height}"
        ).stdout.decode().strip()
        if client_size != "%dx%d" % (width, height):
            fail("client attached at %s instead of %dx%d" %
                (client_size, width, height))
        drain_until_quiet(fd, 0.2, 5)

        for pane in paths.values():
            open(pane["preopen"], "w", encoding="utf-8").close()
        wait_for(
            lambda: all(os.path.exists(paths[name]["preopened"])
                for name in paths),
            2,
            "applications did not open synchronized pre-resize frames",
        )
        wait_for(
            lambda: b"LEFT_OPEN_" in run(
                "capture-pane", "-p", "-t", left
            ).stdout and b"RIGHT_OPEN_" in run(
                "capture-pane", "-p", "-t", right
            ).stdout,
            2,
            "open synchronized frames did not reach the backing screens",
        )
        drain_until_quiet(fd, 0.05, 1)

        for pane in paths.values():
            open(pane["arm"], "w", encoding="utf-8").close()

        before_widths = (
            int(run("display-message", "-p", "-t", left,
                "#{pane_width}").stdout),
            int(run("display-message", "-p", "-t", right,
                "#{pane_width}").stdout),
        )
        run("resize-pane", "-t", left, "-R", "10")
        wait_for(
            lambda: all(os.path.exists(paths[name]["resized"])
                for name in paths),
            2,
            "both applications did not receive SIGWINCH",
        )

        before_release = read_available(fd, 0.03)
        if before_release:
            fail("client received %d bytes before applications repainted" %
                len(before_release))

        open(paths["LEFT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["LEFT"]["painted"]),
            0.05,
            "left application did not finish its synchronized repaint",
        )
        after_one = read_available(fd, 0.02)
        if b"LEFT_AFTER1_00_" in after_one:
            fail("left post-resize frame reached the client before every "
                "application repainted")
        if b"RIGHT_AFTER1_00_" in after_one:
            fail("right post-resize frame reached the client before it "
                "repainted")
        if after_one:
            fail("client emitted %d bytes before every application repainted: "
                "%s" % (len(after_one), after_one.hex()))

        open(paths["RIGHT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["RIGHT"]["painted"]),
            0.05,
            "right application did not finish its synchronized repaint",
        )
        final = drain_until_quiet(fd, release_quiet, 2)

        if b"LEFT_AFTER1_00_" not in final:
            client_size = run(
                "list-clients", "-F", "#{client_width}x#{client_height}"
            ).stdout.decode().strip()
            fail("final redraw does not contain the left post-resize frame "
                "(before=%d, after-one=%d, final=%d, left-before=%s, "
                "right-before=%s, right-after=%s, sync=%d/%d, client=%s)" %
                (len(before_release), len(after_one), len(final),
                b"LEFT_BEFORE_00_" in final,
                b"RIGHT_BEFORE_00_" in final,
                b"RIGHT_AFTER1_00_" in final,
                final.count(sync_start), final.count(sync_end), client_size))
        if b"RIGHT_AFTER1_00_" not in final:
            fail("final redraw does not contain the right post-resize frame")
        if final.count(sync_start) != 1 or final.count(sync_end) != 1:
            fail("final redraw was not one synchronized client transaction: "
                "%d starts, %d ends" %
                (final.count(sync_start), final.count(sync_end)))

        later = read_available(fd, 0.2)
        if later:
            fail("client received a late corrective redraw of %d bytes" %
                len(later))

        after_widths = (
            int(run("display-message", "-p", "-t", left,
                "#{pane_width}").stdout),
            int(run("display-message", "-p", "-t", right,
                "#{pane_width}").stdout),
        )
        if after_widths != (before_widths[0] + 10, before_widths[1] - 10):
            fail("unexpected final widths: %r -> %r" %
                (before_widths, after_widths))

        for pane in paths.values():
            for key in ("resized", "gate", "painted"):
                os.unlink(pane[key])

        timeout_started = time.monotonic()
        run("resize-pane", "-t", left, "-L", "10")
        wait_for(
            lambda: all(os.path.exists(paths[name]["resized"])
                for name in paths),
            2,
            "both applications did not receive the timeout-case SIGWINCH",
        )
        before_timeout = read_available(fd, 0.03)
        if before_timeout:
            fail("client received %d bytes before the timeout-case repaint" %
                len(before_timeout))

        open(paths["LEFT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["LEFT"]["painted"]),
            0.05,
            "left application did not finish its timeout-case repaint",
        )
        after_timeout_left = read_available(fd, 0.02)
        if b"LEFT_AFTER2_00_" in after_timeout_left:
            fail("timeout-case frame reached the client before the deadline")

        timeout_frame = drain_until_quiet(fd, release_quiet, 2)
        timeout_elapsed = time.monotonic() - timeout_started
        if timeout_elapsed < 0.12:
            fail("resize deadline released too early at %.3fs" %
                timeout_elapsed)
        if timeout_elapsed > 0.8:
            fail("resize deadline released too late at %.3fs" %
                timeout_elapsed)
        if b"LEFT_AFTER2_00_" not in timeout_frame:
            fail("deadline redraw does not contain the completed left frame")
        if b"RIGHT_AFTER2_00_" in timeout_frame:
            fail("deadline redraw contains the blocked right frame")
        if (timeout_frame.count(sync_start) != 1 or
                timeout_frame.count(sync_end) != 1):
            fail("deadline redraw was not one synchronized client transaction: "
                "%d starts, %d ends" %
                (timeout_frame.count(sync_start),
                timeout_frame.count(sync_end)))

        timeout_widths = (
            int(run("display-message", "-p", "-t", left,
                "#{pane_width}").stdout),
            int(run("display-message", "-p", "-t", right,
                "#{pane_width}").stdout),
        )
        if timeout_widths != before_widths:
            fail("unexpected timeout-case widths: %r -> %r" %
                (after_widths, timeout_widths))

        open(paths["RIGHT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["RIGHT"]["painted"]),
            0.05,
            "right application did not finish after the resize deadline",
        )
        right_late = drain_until_quiet(fd, release_quiet, 2)
        if b"RIGHT_AFTER2_00_" not in right_late:
            fail("right application frame was lost after the resize deadline")

        for pane in paths.values():
            for path in pane.values():
                if os.path.exists(path):
                    os.unlink(path)
        run("respawn-pane", "-k", "-t", left, command("LEFT"))
        run("respawn-pane", "-k", "-t", right, command("RIGHT", False))
        wait_for(
            lambda: all(os.path.exists(paths[name]["ready"])
                for name in paths),
            5,
            "mixed-mode applications did not become ready",
        )
        wait_for(
            lambda: b"LEFT_BEFORE_00_" in run(
                "capture-pane", "-p", "-t", left
            ).stdout and b"RIGHT_BEFORE_00_" in run(
                "capture-pane", "-p", "-t", right
            ).stdout,
            5,
            "mixed-mode initial frames did not reach both backing screens",
        )
        drain_until_quiet(fd, 0.2, 5)
        time.sleep(0.3)

        for pane in paths.values():
            open(pane["arm"], "w", encoding="utf-8").close()
        run("resize-pane", "-t", left, "-R", "10")
        wait_for(
            lambda: all(os.path.exists(paths[name]["resized"])
                for name in paths),
            2,
            "mixed-mode applications did not receive SIGWINCH",
        )

        open(paths["RIGHT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["RIGHT"]["painted"]),
            0.05,
            "plain application did not finish its repaint",
        )
        mixed_early = read_available(fd, 0.03)
        if b"RIGHT_AFTER1_00_" in mixed_early:
            fail("plain application frame escaped the active resize barrier")
        if mixed_early:
            fail("client redraw was released before the synchronized repaint")

        open(paths["LEFT"]["gate"], "w", encoding="utf-8").close()
        wait_for(
            lambda: os.path.exists(paths["LEFT"]["painted"]),
            0.05,
            "synchronized application did not finish its mixed-mode repaint",
        )
        mixed_final = drain_until_quiet(fd, release_quiet, 2)
        if b"LEFT_AFTER1_00_" not in mixed_final:
            fail("mixed-mode redraw lost the synchronized application frame")
        if b"RIGHT_AFTER1_00_" not in mixed_final:
            fail("mixed-mode redraw lost the plain application frame")
        if (mixed_final.count(sync_start) != 1 or
                mixed_final.count(sync_end) != 1):
            fail("mixed-mode redraw was not one synchronized transaction: "
                "%d starts, %d ends" %
                (mixed_final.count(sync_start), mixed_final.count(sync_end)))
    finally:
        cleanup(pid, fd)
PY
