#!/usr/bin/env python3
"""Called by test_local_proxy.sh; keep one proxied socket alive across SIGUSR1."""
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

work = Path(sys.argv[1])
domain = sys.argv[2]
server_port, client_port, server_pid = map(int, sys.argv[3:])


def recv_exact(sock, length):
    result = b""
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise AssertionError("existing proxied connection was closed")
        result += chunk
    return result


def openssl(*args):
    subprocess.run(["openssl", *map(str, args)], check=True, timeout=15,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(15)

    def echo():
        with listener.accept()[0] as conn:
            conn.settimeout(15)
            while data := conn.recv(4096):
                conn.sendall(data)

    thread = threading.Thread(target=echo, daemon=True)
    thread.start()
    with socket.create_connection(("127.0.0.1", client_port), timeout=5) as conn:
        conn.sendall(b"\x05\x01\x00")
        assert recv_exact(conn, 2) == b"\x05\x00", "SOCKS negotiation failed"
        conn.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1")
                     + struct.pack("!H", listener.getsockname()[1]))
        head = recv_exact(conn, 4)
        assert head[:2] == b"\x05\x00", "SOCKS connect failed"
        size = {1: 4, 4: 16}.get(head[3])
        if head[3] == 3:
            size = recv_exact(conn, 1)[0]
        assert size is not None
        recv_exact(conn, size + 2)
        conn.sendall(b"before-renewal")
        assert recv_exact(conn, 14) == b"before-renewal"

        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={domain}",
                "-keyout", work / "key.new", "-out", work / "new.csr")
        openssl("x509", "-req", "-in", work / "new.csr", "-CA", work / "ca.pem",
                "-CAkey", work / "ca.key", "-set_serial", "2", "-days", "1",
                "-extfile", work / "extensions", "-out", work / "cert.new")
        expected = ssl.PEM_cert_to_DER_cert((work / "cert.new").read_text())
        os.replace(work / "cert.new", work / "cert.pem")
        os.replace(work / "key.new", work / "key.pem")
        os.kill(server_pid, signal.SIGUSR1)

        context = ssl.create_default_context(cafile=str(work / "ca.pem"))
        for _ in range(30):
            with socket.create_connection(("127.0.0.1", server_port), timeout=2) as tcp:
                with context.wrap_socket(tcp, server_hostname=domain) as tls:
                    if tls.getpeercert(binary_form=True) == expected:
                        break
            time.sleep(0.1)
        else:
            raise AssertionError("server did not load the new certificate")

        # No reconnection: this is the exact socket opened before the key/cert change.
        conn.sendall(b"after-renewal")
        assert recv_exact(conn, 13) == b"after-renewal"
    thread.join(timeout=3)
    assert not thread.is_alive(), "echo connection failed to close"

print("new certificate served; existing authenticated TCP stream survived SIGUSR1: PASS")
