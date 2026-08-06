#!/usr/bin/env python3
"""Hold the Secure Boot signing key, and hand out signatures for modules.

This runs on the signer host and nowhere else. It exists so the builder --
an always-on box that pulls from the internet, runs a package manager, and
executes a Containerfile -- never has the private key on it. The builder
sends an unsigned module; this returns a detached signature; the builder
attaches it with the real sign-file. See scripts/sign-file-oracle for the
other half.

Losing this key is expensive in a way losing the builder is not: recovery
means regenerating it, updating the committed MOK.der, and re-enrolling
through MokManager at boot on every machine running Pulsar. That asymmetry
is the reason for the split.

Deliberately small and dependency-free. The whole attack surface is one
POST route, and it should stay readable in a single sitting.

  POST /sign-module   Authorization: Bearer <token>
                      body: the uncompressed .ko
                      200:  the detached DER signature (application/octet-stream)

  GET  /cert          Authorization: Bearer <token>
                      200:  this signer's certificate, DER

  GET  /health        no auth; liveness only, reveals nothing

/cert exists so the build signs with the cert belonging to the key that
actually signed. Handing sign-file the committed MOK.der instead would make
phase 5 of Containerfile.nvidia vacuous -- it would be comparing MOK.der
against itself and would pass even if the signer held an entirely different
key. Fetching the cert here keeps that check meaningful: it asserts the
signer's cert is the one the image tells users to enrol.

Environment:
  PULSAR_SIGNER_KEY     private key (PEM), default /etc/pulsar-signer/key.pem
  PULSAR_SIGNER_CERT    certificate (DER), default /etc/pulsar-signer/cert.der
  PULSAR_SIGNER_TOKEN_FILE  file holding the bearer token
  PULSAR_SIGNER_SIGN_FILE   path to the kernel's sign-file binary
  PULSAR_SIGNER_BIND    address to bind, default 127.0.0.1 (set to the VPC
                        private IP in production; never 0.0.0.0)
  PULSAR_SIGNER_PORT    default 8099
  PULSAR_SIGNER_MAX_MB  reject bodies larger than this, default 256

Bind to the private interface and put a cloud firewall in front of it that
admits only the builder. The token is a second lock, not the only one.
"""

import hmac
import http.server
import os
import pathlib
import subprocess
import sys
import tempfile
import time

KEY = os.environ.get("PULSAR_SIGNER_KEY", "/etc/pulsar-signer/key.pem")
CERT = os.environ.get("PULSAR_SIGNER_CERT", "/etc/pulsar-signer/cert.der")
SIGN_FILE = os.environ.get("PULSAR_SIGNER_SIGN_FILE", "/usr/bin/sign-file")
BIND = os.environ.get("PULSAR_SIGNER_BIND", "127.0.0.1")
PORT = int(os.environ.get("PULSAR_SIGNER_PORT", "8099"))
MAX_BYTES = int(os.environ.get("PULSAR_SIGNER_MAX_MB", "256")) * 1024 * 1024

# Only the algorithms the kernel actually accepts for module signatures, so a
# caller cannot talk this into signing under something weaker.
ALLOWED_HASHES = {"sha256", "sha384", "sha512"}


def _load_token() -> bytes:
    path = os.environ.get("PULSAR_SIGNER_TOKEN_FILE")
    if not path:
        sys.exit("PULSAR_SIGNER_TOKEN_FILE is not set")
    token = pathlib.Path(path).read_bytes().strip()
    if len(token) < 32:
        sys.exit("signer token is too short; use at least 32 bytes of entropy")
    return token


TOKEN = _load_token()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "pulsar-signer"
    sys_version = ""

    # The default logs the request line, which is fine, but every signature
    # request deserves a durable record: who asked, for what, how big.
    def log_message(self, fmt, *args):
        sys.stderr.write(
            "%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                            self.client_address[0], fmt % args)
        )

    def _refuse(self, code, why):
        body = (why + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.log_message("refused %d: %s", code, why)

    def _authorised(self) -> bool:
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        # constant time: a timing oracle on the token would undo the point
        return hmac.compare_digest(header[len(prefix):].encode(), TOKEN)

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"ok\n")
        elif self.path == "/cert":
            if not self._authorised():
                return self._refuse(401, "unauthorised")
            cert = pathlib.Path(CERT).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(cert)))
            self.end_headers()
            self.wfile.write(cert)
            self.log_message("served cert (%d bytes)", len(cert))
        else:
            self._refuse(404, "not found")

    def do_POST(self):
        if self.path != "/sign-module":
            return self._refuse(404, "not found")
        if not self._authorised():
            return self._refuse(401, "unauthorised")

        hash_algo = self.headers.get("X-Pulsar-Hash-Algo", "sha256")
        if hash_algo not in ALLOWED_HASHES:
            return self._refuse(400, "unsupported hash algorithm")

        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._refuse(411, "length required")
        if length <= 0 or length > MAX_BYTES:
            return self._refuse(413, "body too large or empty")

        module = self.rfile.read(length)
        if len(module) != length:
            return self._refuse(400, "short read")
        # ELF magic. This service signs kernel modules; anything else is a
        # caller doing something it should not be, and is worth refusing
        # loudly rather than signing and finding out later.
        if not module.startswith(b"\x7fELF"):
            return self._refuse(400, "not an ELF object")

        name = self.headers.get("X-Pulsar-Module", "module")[:128]
        self.log_message("sign-module %s (%d bytes, %s)", name, length, hash_algo)

        try:
            signature = self._sign(module, hash_algo)
        except subprocess.CalledProcessError as exc:
            self.log_message("sign-file failed: %s", exc.stderr.decode()[:400])
            return self._refuse(500, "signing failed")
        except Exception as exc:  # noqa: BLE001 - never leak internals to callers
            self.log_message("signing error: %r", exc)
            return self._refuse(500, "signing failed")

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(signature)))
        self.end_headers()
        self.wfile.write(signature)
        self.log_message("signed %s -> %d byte signature", name, len(signature))

    def _sign(self, module: bytes, hash_algo: str) -> bytes:
        """sign-file -d writes <module>.p7s and leaves the module untouched."""
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "module.ko"
            path.write_bytes(module)
            subprocess.run(
                [SIGN_FILE, "-d", hash_algo, KEY, CERT, str(path)],
                check=True, capture_output=True,
            )
            sig = path.with_suffix(".ko.p7s")
            if not sig.exists():
                raise FileNotFoundError(f"no detached signature at {sig}")
            data = sig.read_bytes()
        if not data.startswith(b"\x30"):
            raise ValueError("sign-file produced something that is not DER")
        return data


def main():
    for path in (KEY, CERT, SIGN_FILE):
        if not os.path.exists(path):
            sys.exit(f"missing: {path}")
    if BIND == "0.0.0.0":  # noqa: S104 - refusing it is the point
        sys.exit("refusing to bind 0.0.0.0; bind the private interface")

    httpd = http.server.ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write(f"pulsar-signer listening on {BIND}:{PORT}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
