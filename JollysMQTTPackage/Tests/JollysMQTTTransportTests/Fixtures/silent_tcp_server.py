#!/usr/bin/env python3

import pathlib
import socket
import sys

port = int(sys.argv[1])
state_directory = pathlib.Path(sys.argv[2])
state_directory.mkdir(parents=True, exist_ok=True)

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(1)
    (state_directory / "ready").touch()
    connection, _ = server.accept()
    (state_directory / "accepted").touch()
    with connection:
        while connection.recv(4096):
            pass
    (state_directory / "closed").touch()
