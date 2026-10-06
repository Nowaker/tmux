import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import termios
import tty
from types import FrameType


def main() -> None:
    root = Path(sys.argv[1])
    tty.setraw(0)

    def identity() -> str:
        return json.dumps([os.getpid(), os.ttyname(0), os.getsid(0),
                           os.getpgrp(), os.tcgetpgrp(0)])

    def record(name: str, text: str) -> None:
        (root / name).write_text(text)

    def redraw(_signum: int, _frame: FrameType | None) -> None:
        os.write(1, b"\x1b[2J\x1b[Hfullscreen-redraw\x1b[3;5H")
        record("redraw", identity())

    def burst(_signum: int, _frame: FrameType | None) -> None:
        record("burst-start", "1")
        payload = b"0123456789abcdef" * 131072
        written = 0
        while written < len(payload):
            written += os.write(1, payload[written:])
            record("burst-progress", str(written))
        record("burst-done", hashlib.sha256(payload).hexdigest())

    signal.signal(signal.SIGWINCH, redraw)
    signal.signal(signal.SIGUSR1, burst)

    def parked_output(_signum: int, _frame: FrameType | None) -> None:
        os.write(1, (root / "park-output").read_bytes())
        record("park-output-done", "1")

    signal.signal(signal.SIGUSR2, parked_output)
    record("identity", identity())
    os.write(1, b"\x1b[?1049h\x1b[?1h\x1b[2J\x1b[Hviewport-before\x1b[3;5H")
    record("ready", "1")
    while True:
        command = os.read(0, 1)
        match command:
            case b"i":
                record("identity-after", identity())
                os.write(1, b"identity-after")
            case b"b":
                burst(0, None)
            case b"f":
                os.write(1, b"\x1b[")
                record("fragment", "1")
            case b"g":
                os.write(1, b"2J\x1b[Hfragment-complete")
                record("fragment-done", "1")
            case b"u":
                os.write(1, b"\xe2")
                record("utf8", "1")
            case b"v":
                os.write(1, b"\x82\xac")
                record("utf8-done", "1")
            case b"s":
                os.write(1, b"\x1b[?2026h")
                record("sync", "1")
            case b"t":
                os.write(1, b"\x1b[?2026l")
                record("sync-done", "1")
            case b"a":
                key = os.read(0, 3)
                record("cursor-key", key.hex())
            case b"r":
                os.write(1, b"\x1b[2b")
                record("repeat-done", "1")
            case b"p":
                os.write(1, b"R")
                record("print-done", "1")
            case b"j":
                child = os.fork()
                if child == 0:
                    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                    os.setpgid(0, 0)
                    os.tcsetpgrp(0, os.getpgrp())
                    record("job", identity())
                    signal.signal(signal.SIGTSTP, signal.SIG_DFL)
                    os.kill(os.getpid(), signal.SIGTSTP)
                    record("job-resumed", identity())
                    os._exit(0)
                os.waitpid(child, os.WUNTRACED)
                record("job-stopped", str(child))
                os.kill(child, signal.SIGCONT)
                os.waitpid(child, 0)
                signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                os.tcsetpgrp(0, os.getpgrp())
                record("job-done", identity())
            case b"q" | b"":
                return
            case _:
                os.write(1, command)


if __name__ == "__main__":
    main()
