#!/bin/sh

# Losing an attached client that vanished without saying so recalculates
# window sizes; losing a command-line client (which never has a session) must
# not change them.

PATH=/bin:/usr/bin:/usr/local/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest$$ -f/dev/null"
trap '$TMUX kill-server 2>/dev/null' 0 1 15

$TMUX new -d 'sleep 1000' || exit 1
$TMUX set -g window-size smallest || exit 1
python3 - $TMUX <<'EOF2' || exit 1
import fcntl, os, pty, signal, struct, subprocess, sys, termios, time

tmux = sys.argv[1:]

def attach(rows, cols):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm"
        os.execvp(tmux[0], tmux + ["attach"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.set_blocking(fd, False)
    return pid, fd

clients = []

def drain():
    for _, fd in clients:
        try:
            os.read(fd, 65536)
        except OSError:
            pass

def window_size():
    return subprocess.run(tmux + ["display", "-p", "#{window_width}x#{window_height}"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip().decode()

def wait_for(expected, what):
    for i in range(200):
        drain()
        if window_size() == expected:
            return
        time.sleep(0.05)
    print("%s: window is %s, expected %s" % (what, window_size(), expected))
    sys.exit(1)

# Each client loses one row to the status line.
clients.append(attach(40, 120))
wait_for("120x39", "first client")
clients.append(attach(20, 60))
wait_for("60x19", "smaller client")

for i in range(20):
    subprocess.run(tmux + ["show", "-gqv", "@unset"], stdout=subprocess.DEVNULL)
    drain()
if window_size() != "60x19":
    print("command clients changed the window to %s" % window_size())
    sys.exit(1)

# SIGKILL, so the client vanishes without MSG_EXITING (which recalculates on
# its own) and the server only learns of it when it loses the connection.
pid, fd = clients.pop()
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
os.close(fd)
wait_for("120x39", "smaller client gone")

for pid, fd in clients:
    os.kill(pid, signal.SIGTERM)
    os.waitpid(pid, 0)
    os.close(fd)
EOF2

exit 0
