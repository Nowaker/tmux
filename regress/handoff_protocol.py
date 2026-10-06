import array
import hashlib
import os
from pathlib import Path
import signal
import socket
import struct
import time

from .handoff_wait import wait_for


HEADER = struct.Struct("=21i32s4i35s1x")


def request(operation: int) -> bytes:
    fields = [0] * 21
    fields[:4] = [0x50545931, 1, operation, HEADER.size]
    fields[19] = os.getpid()
    return HEADER.pack(*fields, b"", 0, 0, 0, 0, b"")


def receive(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        assert chunk, "protocol EOF"
        result.extend(chunk)
    return bytes(result)


def reserve(directory: Path) -> tuple[socket.socket, int, bytes, bytes]:
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(5)
    connection.connect(str(directory / "keeper"))
    connection.sendall(request(5))
    header, ancillary, _, _ = connection.recvmsg(HEADER.size, socket.CMSG_SPACE(4))
    header += receive(connection, HEADER.size - len(header))
    fields = HEADER.unpack(header)
    assert fields[2] == 2 and fields[4] == 2
    descriptors = array.array("i")
    for level, kind, data in ancillary:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            descriptors.frombytes(data)
    assert len(descriptors) == 1
    snapshot = receive(connection, fields[6])
    fifo = receive(connection, fields[5])
    return connection, descriptors[0], snapshot, fifo


def exercise(directory: Path, root: Path, pid: int) -> None:
    os.kill(pid, signal.SIGUSR1)
    wait_for(lambda: (root / "burst-start").exists())
    time.sleep(0.2)
    connection, master, snapshot, fifo = reserve(directory)
    assert len(fifo) == 1024 * 1024, len(fifo)
    assert not (root / "burst-done").exists(), "backpressure failed"
    assert fifo == b"0123456789abcdef" * 65536
    connection.close()
    os.close(master)
    with socket.socket(socket.AF_UNIX) as malformed:
        malformed.connect(str(directory / "keeper"))
        malformed.sendall(b"bad")
    connection, master, snapshot_after, fifo_after = reserve(directory)
    assert snapshot_after == snapshot and fifo_after == fifo
    connection.sendall(request(3))
    ack = HEADER.unpack(receive(connection, HEADER.size))
    assert ack[2] == 4 and ack[4] == 3 and ack[19] == os.getpid()
    connection.close()
    try:
        result = bytearray(fifo)
        deadline = time.monotonic() + 10
        os.set_blocking(master, False)
        while len(result) < 2 * 1024 * 1024:
            assert time.monotonic() < deadline
            try:
                chunk = os.read(master, 65536)
            except BlockingIOError:
                time.sleep(0.01)
                continue
            assert chunk
            result.extend(chunk)
        expected = b"0123456789abcdef" * 131072
        assert result == expected
        wait_for(lambda: (root / "burst-done").exists())
        print("PASS reservation rollback, malformed peer, backpressure, byte parity",
              len(result), hashlib.sha256(result).hexdigest(), flush=True)
        os.write(master, b"q")
    finally:
        os.close(master)
