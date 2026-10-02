#!/usr/bin/python3
"""Drive a VM through its QMP socket: screenshots and keyboard.

    qmp.py SOCKET shot OUT.png        a screendump (PNG)
    qmp.py SOCKET keys KEY...         qemu key names, e.g. meta_l ctrl-alt-t ret
    qmp.py SOCKET type TEXT           types TEXT (US layout), no Enter
    qmp.py SOCKET wait-shot OUT.png SECONDS
                                      a screendump every SECONDS into OUT-<n>.png
                                      until killed (for a timelapse)
"""
import json
import socket
import sys
import time

SHIFTED = {'~': 'grave_accent', '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal', '{': 'bracket_left',
           '}': 'bracket_right', '|': 'backslash', ':': 'semicolon', '"': 'apostrophe', '<': 'comma',
           '>': 'dot', '?': 'slash'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
         '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash',
         '`': 'grave_accent', '\n': 'ret'}


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        json.loads(self.f.readline())          # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                if "error" in r:
                    raise SystemExit(f"QMP {name}: {r['error']}")
                return r["return"]

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})

    def key(self, k):
        self.hmp(f"sendkey {k}")
        time.sleep(0.04)

    def type(self, text):
        for ch in text:
            if ch.isalpha():
                self.key(f"shift-{ch.lower()}" if ch.isupper() else ch)
            elif ch.isdigit():
                self.key(ch)
            elif ch in PLAIN:
                self.key(PLAIN[ch])
            elif ch in SHIFTED:
                self.key(f"shift-{SHIFTED[ch]}")
            else:
                raise SystemExit(f"cannot type {ch!r}")


def main():
    q = QMP(sys.argv[1])
    what = sys.argv[2]
    if what == "shot":
        q.cmd("screendump", filename=sys.argv[3], format="png")
    elif what == "keys":
        for k in sys.argv[3:]:
            q.key(k)
    elif what == "type":
        q.type(" ".join(sys.argv[3:]))
    elif what == "wait-shot":
        base, every, n = sys.argv[3].removesuffix(".png"), float(sys.argv[4]), 0
        while True:
            q.cmd("screendump", filename=f"{base}-{n:05d}.png", format="png")
            n += 1
            time.sleep(every)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
