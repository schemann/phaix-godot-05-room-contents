#!/usr/bin/env python3
"""Lists every GDScript error and warning of the project (exit 1 if there is any).

The engine prints GDScript warnings only in the editor, never on the command line,
so this starts a headless editor and asks its language server for the diagnostics
of every .gd file. Needs `godot` on the PATH.
Usage: tools/check_warnings.py [project dir]   (default: the project this file is in)"""
import json, os, socket, subprocess, sys, time

project = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
with socket.socket() as probe:  # a free port for the language server
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]

proc = subprocess.Popen(["godot", "--headless", "--editor", "--path", project, "--lsp-port", str(port)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sock = None
try:
    for _ in range(100):
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError:
            time.sleep(0.5)
    if sock is None:
        sys.exit("language server did not start")
    sock.settimeout(1.0)
    buf = b""

    def send(msg):
        body = json.dumps(msg).encode()
        sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def read_messages():
        global buf
        try:
            data = sock.recv(1 << 20)
            if not data:
                return []
            buf += data
        except socket.timeout:
            pass
        out = []
        while True:
            head, sep, rest = buf.partition(b"\r\n\r\n")
            if not sep:
                break
            length = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
            if len(rest) < length:
                break
            out.append(json.loads(rest[:length]))
            buf = rest[length:]
        return out

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"processId": os.getpid(), "rootUri": "file://" + project, "capabilities": {}}})
    deadline = time.time() + 30
    while time.time() < deadline and not any(m.get("id") == 1 for m in read_messages()):
        pass
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    files = []
    for base, dirs, names in os.walk(project):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        files += [os.path.join(base, n) for n in names if n.endswith(".gd")]
    files.sort()
    for f in files:
        send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
              "params": {"textDocument": {"uri": "file://" + f, "languageId": "gdscript", "version": 1,
                                          "text": open(f).read()}}})
    seen = {}
    quiet = time.time() + 5
    deadline = time.time() + 60
    while time.time() < deadline and time.time() < quiet:
        for m in read_messages():
            if m.get("method") == "textDocument/publishDiagnostics":
                seen[m["params"]["uri"]] = m["params"]["diagnostics"]
                quiet = time.time() + 3
        if len(seen) == len(files):
            break
    problems = 0
    for f in files:
        diags = seen.get("file://" + f)
        if diags is None:
            print("NO DIAGNOSTICS RECEIVED", os.path.relpath(f, project))
            problems += 1
            continue
        for d in diags:
            problems += 1
            print("%s:%d: %s" % (os.path.relpath(f, project), d["range"]["start"]["line"] + 1, d["message"]))
    print("%d files checked, %d problems" % (len(files), problems))
    sys.exit(1 if problems else 0)
finally:
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
