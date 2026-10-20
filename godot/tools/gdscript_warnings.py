#!/usr/bin/env python3
"""Report GDScript errors and warnings from Godot's own language server.

The headless runtime parses scripts but does not print GDScript warnings, so
the editor's LSP is the only place they are reported. This starts a headless
editor, opens every `src/` and `tools/` script over the Language Server
Protocol, and prints what it finds.

    godot/tools/gdscript_warnings.py

Set `GODOT_BIN` to the Godot executable (the same variable `gates.sh` reads)
and `LSP_PORT` if the default port is taken. Exits 1 on any diagnostic and 2
if the server never published a result for a script, so it can be a gate.
"""
import glob
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote

GODOT = os.environ.get(
    "GODOT_BIN", r"C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe")
PROJECT = str(Path(__file__).resolve().parent.parent)
PORT = int(os.environ.get("LSP_PORT", "6017"))

proc = subprocess.Popen(
    [GODOT, "--headless", "--editor", "--path", PROJECT,
     "--lsp-port", str(PORT)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)

sock = None
deadline = time.time() + 90
while time.time() < deadline:
    try:
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=1)
        break
    except OSError:
        time.sleep(0.5)
if sock is None:
    proc.terminate()
    raise SystemExit("could not connect to the GDScript LSP on port %d" % PORT)

sock.settimeout(1.0)
buf = b""


def send(obj):
    data = json.dumps(obj).encode()
    sock.sendall(b"Content-Length: %d\r\n\r\n" % len(data) + data)


def read_msg(timeout=1.0):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        head_end = buf.find(b"\r\n\r\n")
        if head_end >= 0:
            head = buf[:head_end]
            length = None
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1].strip())
            if length is not None and len(buf) - head_end - 4 >= length:
                body = buf[head_end + 4:head_end + 4 + length]
                buf = buf[head_end + 4 + length:]
                return json.loads(body)
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            return None
        buf += chunk
    return None


def reply(request):
    send({"jsonrpc": "2.0", "id": request["id"], "result": None})


def wait_for(response_id, timeout=60.0):
    end = time.time() + timeout
    while time.time() < end:
        msg = read_msg(1.0)
        if msg is None:
            continue
        if msg.get("id") == response_id and ("result" in msg or "error" in msg):
            return msg
        if "id" in msg and "method" in msg:
            reply(msg)
    raise SystemExit("LSP did not answer request %s" % response_id)


send({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "processId": None,
        "rootUri": Path(PROJECT).as_uri(),
        "capabilities": {},
    },
})
wait_for(1)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# Let the editor finish its project scan before opening documents.
time.sleep(6.0)

files = sorted(glob.glob(os.path.join(PROJECT, "src", "*.gd")))
files += sorted(glob.glob(os.path.join(PROJECT, "tools", "*.gd")))

for path in files:
    with open(path, "r", encoding="utf-8", newline="") as handle:
        text = handle.read()
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": Path(path).as_uri(),
                "languageId": "gdscript",
                "version": 1,
                "text": text,
            }
        },
    })

wanted = {unquote(Path(path).as_uri()): path for path in files}
found = {}
end = time.time() + 45
while time.time() < end:
    msg = read_msg(1.0)
    if msg is None:
        continue
    if "id" in msg and "method" in msg:
        reply(msg)
        continue
    if msg.get("method") != "textDocument/publishDiagnostics":
        continue
    params = msg.get("params", {})
    uri = unquote(params.get("uri", ""))
    if uri in wanted:
        found[uri] = params.get("diagnostics", [])

total = 0
for uri in sorted(found):
    diags = found[uri]
    if not diags:
        continue
        print("\n" + os.path.relpath(wanted[uri], PROJECT))
    for d in diags:
        severity = {1: "error", 2: "warning", 3: "info", 4: "hint"}.get(
            d.get("severity"), "?")
        line = d.get("range", {}).get("start", {}).get("line", -1) + 1
        code = d.get("code", "")
        print("  %s:%s: %s [%s]" % (
            severity, line, d.get("message", ""), code))
        total += 1

missing = [os.path.relpath(wanted[u], PROJECT)
           for u in wanted if u not in found]
if missing:
    print("\nno diagnostics published for: " + ", ".join(missing))
    print("\n%d diagnostic(s) across %d file(s); %d file(s) unanswered" % (
        total, len(found), len(missing)))
    status = 2
else:
    print("\n%d diagnostic(s) across %d file(s)" % (total, len(found)))
    status = 1 if total else 0

send({"jsonrpc": "2.0", "id": 999, "method": "shutdown", "params": None})
try:
    wait_for(999, timeout=5)
except SystemExit:
    pass
send({"jsonrpc": "2.0", "method": "exit", "params": None})
sock.close()
proc.terminate()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
sys.exit(status)
