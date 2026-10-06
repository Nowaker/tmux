import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from .handoff_wait import wait_for


def main() -> None:
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else "./tmux").resolve())
    environment = dict(os.environ)
    environment.pop("TMUX", None)
    environment.pop("TMUX_PANE", None)
    fixture = Path(__file__).with_name("handoff-fixture.py").resolve()
    with tempfile.TemporaryDirectory(prefix="pty-handoff-") as scratch:
        root = Path(scratch)
        directory = root / "park"
        directory.mkdir(mode=0o700)
        address = str(root / "server")

        def tmux(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
            result = subprocess.run([binary, "-S", address, "-f", "/dev/null", *arguments],
                                  env=environment, capture_output=True, text=True,
                                  check=False, timeout=15)
            if check:
                assert result.returncode == 0, (arguments, result.stdout, result.stderr)
            return result

        def send(key: str) -> None:
            tmux("send-keys", "-t", target, "-l", key)

        def ready(name: str) -> None:
            wait_for(lambda: (root / name).exists())

        def cancel() -> None:
            nonlocal keeper
            tmux("handoff-cancel", str(directory))
            wait_for(lambda: not (directory / "keeper").exists())
            wait_for(lambda: subprocess.run(["ps", "-p", str(keeper)],
                                           capture_output=True).returncode != 0)
            keeper = 0

        def park() -> str:
            deadline = time.monotonic() + 5
            while True:
                result = tmux("park-pane", "-t", target, str(directory), check=False)
                if result.returncode == 0:
                    return result.stdout.strip()
                assert time.monotonic() < deadline, result.stderr
                time.sleep(0.01)

        keeper = 0
        target = "%0"
        try:
            command = shlex.join([sys.executable, str(fixture), str(root)])
            tmux("new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24", command)
            tmux("set-option", "-g", "remain-on-exit", "on")
            ready("ready")
            (directory / "keeper").write_text("occupied")
            assert tmux("park-pane", str(directory), check=False).returncode != 0
            assert (directory / "keeper").read_text() == "occupied"
            (directory / "keeper").unlink()
            directory.chmod(0o755)
            assert tmux("park-pane", str(directory), check=False).returncode != 0
            directory.chmod(0o700)
            send("f")
            ready("fragment")
            time.sleep(0.05)
            assert tmux("park-pane", str(directory), check=False).returncode != 0
            send("g")
            ready("fragment-done")
            send("u")
            ready("utf8")
            time.sleep(0.05)
            assert tmux("park-pane", str(directory), check=False).returncode != 0
            send("v")
            ready("utf8-done")
            send("s")
            ready("sync")
            time.sleep(0.05)
            assert tmux("park-pane", str(directory), check=False).returncode != 0
            send("t")
            ready("sync-done")
            send("p")
            ready("print-done")
            wait_for(lambda: "R" in tmux("capture-pane", "-p").stdout)
            before = json.loads((root / "identity").read_text())
            viewport = tmux("capture-pane", "-p").stdout
            old_server = int(tmux("display-message", "-p", "#{pid}").stdout)
            receipt = park()
            print("park:", receipt, flush=True)
            keeper = int(receipt.split("keeper=")[1].split()[0])
            assert (directory / "keeper").stat().st_mode & 0o777 == 0o600
            tmux("respawn-pane", "-t", target, "cat")
            send("placeholder-input")
            tmux("send-keys", "-t", target, "Enter")
            wait_for(lambda: "placeholder-input" in tmux("capture-pane", "-p").stdout)
            parked_status = tmux("handoff-status", str(directory)).stdout
            assert f"keeper={keeper} " in parked_status
            assert f"pid={before[0]} " in parked_status
            print("PASS parked placeholder respawn accepts input; keeper identity unchanged")
            tmux("kill-server")
            wait_for(lambda: subprocess.run(["ps", "-p", str(old_server)],
                                           capture_output=True).returncode != 0)
            os.kill(before[0], 0)
            tmux("new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24", "sleep 60")
            target = tmux("new-window", "-k", "-t", "fixture:0", "-P", "-F", "#{pane_id}", "").stdout.strip()
            tmux("set-option", "-g", "remain-on-exit", "on")
            fault_directory = root / "fault"
            fault_directory.mkdir(mode=0o700)
            from .handoff_fault import drop_commit_receipt
            worker = drop_commit_receipt(fault_directory, directory / "keeper")
            failure = tmux("adopt-pane", "-t", target, str(fault_directory), check=False)
            assert failure.returncode != 0, failure.stdout
            worker.join(timeout=10)
            assert not worker.is_alive()
            suspended_identity = tmux("display-message", "-p", "#{pane_pid}:#{pane_tty}").stdout
            for respawn in ("respawn-pane", "respawn-window"):
                refused = tmux(respawn, "-k", "-t", target, "cat", check=False)
                assert refused.returncode != 0, refused.stdout
                assert "unresolved handoff" in refused.stderr, refused.stderr
                assert tmux("display-message", "-p", "#{pane_pid}:#{pane_tty}").stdout == suspended_identity
            print("adopt recovered:", tmux("adopt-pane", "-t", target, str(directory)).stdout.strip())
            print("PASS lost commit ACK and failed status probe: respawns rejected; original descriptor recovered")
            assert tmux("capture-pane", "-p").stdout == viewport
            send("r")
            ready("repeat-done")
            wait_for(lambda: "RRR" in tmux("capture-pane", "-p").stdout)
            send("i")
            ready("identity-after")
            assert json.loads((root / "identity-after").read_text()) == before
            send("a")
            tmux("send-keys", "-t", target, "Up")
            ready("cursor-key")
            assert (root / "cursor-key").read_text() == "1b4f41"
            send("j")
            ready("job-done")
            assert json.loads((root / "job-done").read_text()) == before
            os.kill(before[0], signal.SIGWINCH)
            ready("redraw")
            wait_for(lambda: "fullscreen-redraw" in tmux("capture-pane", "-p").stdout)
            assert tmux("adopt-pane", str(directory), check=False).returncode != 0
            print("identity:", before, "old-server:", old_server,
                  "new-server:", tmux("display-message", "-p", "#{pid}").stdout.strip())
            send("q")
            wait_for(lambda: tmux("display-message", "-p", "#{pane_dead}").stdout.strip() == "1")
            assert tmux("display-message", "-p", "#{pane_dead_status}").stdout.strip() == ""
            cancel()
            (root / "ready").unlink()
            target = tmux("new-window", "-k", "-t", "fixture:0", "-P", "-F", "#{pane_id}", command).stdout.strip()
            ready("ready")
            cancel_pid = json.loads((root / "identity").read_text())[0]
            tmux("select-pane", "-d", "-t", target)
            receipt = park()
            keeper = int(receipt.split("keeper=")[1].split()[0])
            tmux("respawn-pane", "-t", target, "cat")
            assert tmux("display-message", "-p", "#{pane_input_off}").stdout.strip() == "1"
            print("PASS parked placeholder respawn preserves preexisting user input suppression")
            cancel()
            wait_for(lambda: subprocess.run(["ps", "-p", str(cancel_pid)],
                                           capture_output=True).returncode != 0)
            print("PASS precommit refusal preserves endpoint, private permissions, parked cancel closes PTY")
            print("PASS identity, server exit, cursor encoding, viewport, job control, redraw, EOF, cleanup")
            (root / "ready").unlink()
            target = tmux("new-window", "-k", "-t", "fixture:0", "-P", "-F", "#{pane_id}", command).stdout.strip()
            ready("ready")
            before = json.loads((root / "identity").read_text())
            for fragment, finish, expected in [(b"\xe2", "v", "\u20ac"),
                                                (b"\x1b[", "g", "fragment-complete")]:
                receipt = park()
                keeper = int(receipt.split("keeper=")[1].split()[0])
                (root / "park-output").write_bytes(fragment)
                (root / "park-output-done").unlink(missing_ok=True)
                os.kill(before[0], signal.SIGUSR2)
                ready("park-output-done")
                target = tmux("new-window", "-k", "-t", "fixture:0", "-P", "-F", "#{pane_id}", "").stdout.strip()
                tmux("adopt-pane", "-t", target, str(directory))
                send(finish)
                wait_for(lambda: expected in tmux("capture-pane", "-p").stdout)
                cancel()
            print("PASS FIFO/PTY fragment boundaries: UTF-8 and CSI")
            receipt = park()
            keeper = int(receipt.split("keeper=")[1].split()[0])
            from .handoff_protocol import exercise
            exercise(directory, root, before[0])
            cancel()
        finally:
            tmux("handoff-cancel", str(directory), check=False)
            tmux("kill-server", check=False)


if __name__ == "__main__":
    main()
