#!/bin/sh

# Pane-off and control output backpressure must both resume empty PTY reads.

PATH=/bin:/usr/bin
TERM=screen
export TERM
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
python3 - "$TEST_TMUX" <<'PY'
import os
import select
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path


server = [sys.argv[1], '-Lvt-looprig-control-%d' % os.getpid(), '-f/dev/null']


def tmux(*args: str) -> str:
    return subprocess.check_output(server + list(args), text=True).strip()


def until(predicate: Callable[[], bool], message: str) -> None:
    deadline = time.monotonic() + 15
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(message)
        select.select([], [], [], 0.02)


try:
    tmux('new-session', '-d', '-s', 'control', 'sleep 100')
    tmux('set', '-g', 'automatic-rename', 'off')
    pane = tmux('display', '-p', '#{pane_id}')
    with tempfile.TemporaryDirectory() as directory:
        written = Path(directory) / 'written'
        with subprocess.Popen(server + ['-C', 'attach', '-t', 'control'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as client:
            assert client.stdin is not None
            assert client.stdout is not None
            try:
                until(lambda: bool(tmux('list-clients', '-F', '#{client_name}')),
                      'control client did not attach')
                name = tmux('list-clients', '-F', '#{client_name}')
                tmux('refresh-client', '-t', name, '-A', pane + ':off')
                tmux('respawn-pane', '-k', '-t', pane,
                     "printf 'off-resumed'; : > '%s'; sleep 100" % written)
                until(written.exists, 'pane did not write while off')
                assert 'off-resumed' not in tmux('capture-pane', '-p', '-t', pane), \
                    'pane-off consumed PTY output'
                tmux('refresh-client', '-t', name, '-A', pane + ':on')
                until(lambda: 'off-resumed' in tmux('capture-pane', '-p', '-t', pane),
                      'pane-on did not reenable an empty, disabled input buffer')

                tmux('respawn-pane', '-k', '-t', pane,
                     "perl -e '$|=1; print \"x\" x 1048576; print \"\\r\\npressure-resumed\\r\\n\"; sleep 100'")
                data = b''
                deadline = time.monotonic() + 20
                while b'pressure-resumed' not in data:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, 'backpressure did not resume pane reads'
                    ready, _, _ = select.select([client.stdout], [], [], remaining)
                    assert ready, 'control output timed out after releasing backpressure'
                    chunk = os.read(client.stdout.fileno(), 65536)
                    assert chunk, 'control client exited during output'
                    data = (data + chunk)[-131072:]
                until(lambda: 'pressure-resumed' in tmux('capture-pane', '-p', '-t', pane),
                      'final output was not parsed after control output drained')
            finally:
                client.stdin.close()
                client.terminate()
                client.wait(timeout=5)
finally:
    subprocess.run(server + ['kill-server'], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
PY
