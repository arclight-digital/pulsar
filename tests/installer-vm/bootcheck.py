#!/usr/bin/python3
"""Drive a VM's serial console through a LUKS boot.

    bootcheck.py SOCKET LOG

Waits for the passphrase prompt, sends a WRONG passphrase and requires a
re-prompt, then the right one, then waits for the system to reach a login
prompt or graphical.target. Exit 0 only if every step happened in order.
"""
import re
import socket
import sys
import time

sock_path, log_path = sys.argv[1], sys.argv[2]
RIGHT = b"correct horse battery staple"
log = open(log_path, "wb")
s = socket.socket(socket.AF_UNIX)
for _ in range(100):
    try:
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
s.settimeout(1)
buf = b""


def wait_for(pattern, timeout):
    global buf
    end = time.time() + timeout
    rx = re.compile(pattern)
    while time.time() < end:
        m = rx.search(buf)
        if m:
            buf = buf[m.end():]
            return True
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        log.write(chunk)
        log.flush()
        buf += chunk
    return False


def step(name, ok):
    print(f"{'PASS' if ok else 'FAIL'}  {name}", flush=True)
    if not ok:
        sys.exit(1)


def fresh_prompt(timeout, quiet=3.0):
    """A prompt that is really waiting: the stream ends in the prompt with no
    echoed '*' after it, and nothing more arrives for `quiet` seconds. The
    prompt is redrawn for every echoed keystroke, so a bare regex match on
    "passphrase for" is NOT evidence of a new prompt."""
    global buf
    end = time.time() + timeout
    tail = re.compile(rb"(?i)passphrase for [^\r\n]*?::?\s*$")
    last = time.time()
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            chunk = b""
        if chunk:
            log.write(chunk); log.flush(); buf += chunk; last = time.time()
            continue
        if tail.search(buf[-300:]) and time.time() - last >= quiet:
            buf = b""
            return True
    return False


step("firmware -> shim -> grub -> kernel -> passphrase prompt", fresh_prompt(240))
s.sendall(b"wrong passphrase\r")
step("wrong passphrase is refused and asked again", fresh_prompt(60))
s.sendall(RIGHT + b"\r")
step("right passphrase unlocks and the system boots to a login",
     wait_for(rb"(?i)(login:|Reached target graphical|Started gdm|Reached target Graphical)", 300))
