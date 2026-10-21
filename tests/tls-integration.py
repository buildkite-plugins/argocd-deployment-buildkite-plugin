#!/usr/bin/env python3
"""Local-only ArgoCD CLI TLS fixture; no real credentials or deployments.

Requires Python 3, openssl and an ArgoCD CLI with gRPC-web support:
  python3 tests/tls-integration.py --argocd /path/to/argocd
Use --generate-only DIR to generate certificates on another host, then
--cert-dir DIR --argocd PATH to run in an isolated Linux container.
"""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import ssl
import struct
import subprocess
import tempfile
import threading
import time


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for name, hostname in (("trusted", "localhost"), ("wrong-host", "other.invalid")):
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(directory / f"{name}.key"),
            "-out", str(directory / f"{name}.crt"), "-days", "1",
            "-subj", f"/CN={hostname}", "-addext", f"subjectAltName=DNS:{hostname}",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def token():
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return encode({"alg": "none"}) + "." + encode({"sub": "fake-user", "exp": int(time.time()) + 600}) + "."


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        self.server.requests.append((self.path, body))
        self.respond()

    def respond(self):
        if "session.SessionService/Create" in self.path:
            value = token().encode()
            # SessionResponse.token (protobuf field 1), using a varint length.
            length = len(value)
            encoded_length = bytearray()
            while length > 127:
                encoded_length.append((length & 127) | 128)
                length >>= 7
            encoded_length.append(length)
            payload = b"\x0a" + bytes(encoded_length) + value
        else:
            # Empty Settings protobuf is sufficient for fake username/password login.
            payload = b""
        trailers = b"grpc-status: 0\r\n"
        framed = b"\x00" + struct.pack(">I", len(payload)) + payload
        framed += b"\x80" + struct.pack(">I", len(trailers)) + trailers
        self.send_response(200)
        self.send_header("Content-Type", "application/grpc-web+proto")
        self.send_header("Content-Length", str(len(framed)))
        self.end_headers()
        self.wfile.write(framed)


def check(binary, cert_dir):
    for name, trust, success in (("trusted", True, True), ("trusted", False, False), ("wrong-host", True, False)):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.requests = []
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_dir / f"{name}.crt", cert_dir / f"{name}.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as home:
                # Isolate all CLI configuration, flags, credentials, and CA environment.
                env = {"PATH": os.environ["PATH"], "HOME": home, "XDG_CONFIG_HOME": home}
                if trust:
                    env["SSL_CERT_FILE"] = str(cert_dir / f"{name}.crt")
                result = subprocess.run([
                    binary, "login", f"localhost:{server.server_port}",
                    "--username", "fake-user", "--password", "fake-password",
                    "--skip-test-tls", "--grpc-web", "--config", f"{home}/config",
                ], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
                sent_credentials = any(b"fake-password" in body for _, body in server.requests)
                if success:
                    assert result.returncode == 0 and sent_credentials, result.stderr
                else:
                    assert result.returncode != 0 and not sent_credentials, result.stderr
                    assert "x509" in result.stderr, result.stderr
                print(f"PASS {name}, custom trust={trust}: login success={success}, credentials sent={sent_credentials}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--argocd", default="argocd")
    parser.add_argument("--cert-dir", type=Path)
    parser.add_argument("--generate-only", type=Path)
    args = parser.parse_args()
    if args.generate_only:
        generate(args.generate_only)
    elif args.cert_dir:
        check(args.argocd, args.cert_dir)
    else:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            generate(directory)
            check(args.argocd, directory)
