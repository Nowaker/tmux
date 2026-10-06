from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    source = Path(__file__).resolve().parents[1] / "cmd-handoff-pane.c"
    text = source.read_text()
    functions = text[text.index("static uint64_t\nhandoff_milliseconds"):
                     text.index("static int\nhandoff_send")]
    harness = r"""
#include <sys/types.h>
#include <sys/socket.h>
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>
#define HANDOFF_TIMEOUT 2000
static unsigned calls, polls;
static int
boundary_clock(clockid_t id, struct timespec *now)
{
    const unsigned samples[] = { 0, 1999, 2001 };
    unsigned sample;
    assert(id == CLOCK_MONOTONIC);
    assert(calls < sizeof samples / sizeof samples[0]);
    sample = samples[calls++];
    now->tv_sec = sample / 1000;
    now->tv_nsec = (sample % 1000) * 1000000;
    return 0;
}
static int
boundary_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    assert(count == 1 && fds[0].fd == 7);
    assert(timeout == 1);
    polls++;
    return 1;
}
static ssize_t
boundary_recv(int fd, void *buffer, size_t size, int flags)
{
    (void)buffer;
    assert(fd == 7 && size == 1 && flags == 0);
    errno = EAGAIN;
    return -1;
}
#define clock_gettime boundary_clock
#define poll boundary_poll
#define recv boundary_recv
"""
    harness += functions
    harness += """
int main(void)
{
    char byte;
    assert(handoff_io(7, &byte, 1, 0) == -1);
    assert(calls == 3 && polls == 1);
    return 0;
}
"""
    with tempfile.TemporaryDirectory(prefix="handoff-timeout-") as scratch:
        root = Path(scratch)
        fixture = root / "boundary.c"
        binary = root / "boundary"
        fixture.write_text(harness)
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(fixture),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=5)
    print("PASS deadline boundary: 1999 ms poll is 1 ms; 2001 ms stops without polling")


if __name__ == "__main__":
    main()
