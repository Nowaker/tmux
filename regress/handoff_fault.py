import array
from pathlib import Path
import socket
import threading

from .handoff_protocol import HEADER, receive


def drop_commit_receipt(directory: Path, keeper: Path) -> threading.Thread:
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(directory / "keeper"))
    listener.listen(2)

    def relay() -> None:
        try:
            with listener.accept()[0] as client, socket.socket(socket.AF_UNIX) as owner:
                client.settimeout(10)
                owner.settimeout(10)
                owner.connect(str(keeper))
                owner.sendall(receive(client, HEADER.size))
                header, ancillary, _, _ = owner.recvmsg(HEADER.size, socket.CMSG_SPACE(4))
                header += receive(owner, HEADER.size - len(header))
                fields = HEADER.unpack(header)
                descriptors = array.array("i")
                for level, kind, data in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        descriptors.frombytes(data)
                assert len(descriptors) == 1
                try:
                    client.sendmsg([header], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                              descriptors.tobytes())])
                    client.sendall(receive(owner, fields[5] + fields[6]))
                    owner.sendall(receive(client, HEADER.size))
                    ack = HEADER.unpack(receive(owner, HEADER.size))
                    assert ack[2] == 4 and ack[4] == 3
                finally:
                    import os
                    os.close(descriptors[0])
            with listener.accept()[0] as status:
                status.settimeout(10)
                assert HEADER.unpack(receive(status, HEADER.size))[2] == 6
        finally:
            listener.close()

    worker = threading.Thread(target=relay)
    worker.start()
    return worker
