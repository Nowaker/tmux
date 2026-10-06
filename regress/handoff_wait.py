import time
from typing import Callable


def wait_for(predicate: Callable[[], bool]) -> None:
    deadline = time.monotonic() + 10
    while not predicate():
        assert time.monotonic() < deadline, "fixture deadline exceeded"
        time.sleep(0.01)
