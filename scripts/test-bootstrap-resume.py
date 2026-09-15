#!/usr/bin/env python3
"""Test the bootstrap download() Range-resume logic against a local server.

Runs the template's download() (imported verbatim from
packaging/templates/hermeswebui-bootstrap.py.in) against a stdlib HTTP
server that can honor Range, ignore Range, or truncate every response
(flaky network). Verifies: fresh download, resume from a partial .part,
Range-ignored fallback to a clean restart, oversize/corrupt .part
handling, adoption of a complete .part without network, in-process
retry to success, and progress kept across an exhausted retry cycle
(the "service restart resumes" path observed on the test rig).

Stdlib only; runs on macOS/Linux Python 3. Use: python3 scripts/test-bootstrap-resume.py
"""
import hashlib
import http.server
import importlib
import os
import shutil
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "packaging", "templates",
                        "hermeswebui-bootstrap.py.in")

CAP = 1024 * 1024
DATA = os.urandom(CAP * 2 + CAP // 2)  # 2.5 MiB
SHA = hashlib.sha256(DATA).hexdigest()
SIZE = len(DATA)
BEHAVIOR = {"v": "ok"}  # ok | ignore_range | flaky
HITS = []  # (range_header, status, start, length)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):  # silence
        pass

    def do_GET(self):
        behavior = BEHAVIOR["v"]
        rng = self.headers.get("Range")
        start = 0
        if rng and behavior != "ignore_range":
            start = int(rng.split("=", 1)[1].split("-", 1)[0])
        if behavior == "flaky":
            end = min(SIZE, start + CAP)
        else:
            end = SIZE
        if behavior == "flaky" and end < SIZE and start:
            code, extra = 206, [("Content-Range",
                                 f"bytes {start}-{end - 1}/{SIZE}")]
        elif behavior == "flaky" and end < SIZE:
            code, extra = 200, []
        elif start and behavior != "ignore_range":
            code, extra = 206, [("Content-Range",
                                 f"bytes {start}-{SIZE - 1}/{SIZE}")]
        else:
            code, extra, start = 200, [], 0
            end = min(SIZE, CAP) if behavior == "flaky" else SIZE
        body = DATA[start:end]
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        HITS.append((rng, code, start, len(body)))


def load_bootstrap():
    tmp = tempfile.mkdtemp(prefix="hwui-resume-test-")
    mod_path = os.path.join(tmp, "boot.py")
    shutil.copy(TEMPLATE, mod_path)
    sys.path.insert(0, tmp)
    boot = importlib.import_module("boot")
    boot.RETRY_WAIT_S = 0  # no sleeps in tests
    return boot, tmp


def fresh_dest(tmp, name):
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "artifact.tar.gz")


def expect(cond, msg):
    if not cond:
        print(f"FAIL: {msg}")
        sys.exit(1)
    print(f"PASS: {msg}")


def main():
    boot, tmp = load_bootstrap()
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{srv.server_address[1]}/artifact.tar.gz"
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    # 1. pre-seeded complete dest (the manual unblock path) -> no network
    dest = fresh_dest(tmp, "s1")
    with open(dest, "wb") as f:
        f.write(DATA)
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(HITS == [] and os.path.getsize(dest) == SIZE,
           "pre-seeded verified dest skips network")

    # 2. fresh download, server honors everything
    dest = fresh_dest(tmp, "s2")
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(len(HITS) == 1 and HITS[0][1] == 200
           and open(dest, "rb").read() == DATA,
           "fresh download verifies and installs")

    # 3. partial .part -> Range resume from byte CAP
    dest = fresh_dest(tmp, "s3")
    with open(dest + ".part", "wb") as f:
        f.write(DATA[:CAP])
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(len(HITS) == 1 and HITS[0][1] == 206 and HITS[0][2] == CAP
           and open(dest, "rb").read() == DATA,
           "partial .part resumes via 206 at the right offset")

    # 4. server ignores Range -> clean restart, still verifies
    BEHAVIOR["v"] = "ignore_range"
    dest = fresh_dest(tmp, "s4")
    with open(dest + ".part", "wb") as f:
        f.write(DATA[:CAP])
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(len(HITS) == 1 and HITS[0][1] == 200 and HITS[0][2] == 0
           and open(dest, "rb").read() == DATA,
           "Range-ignored 200 restarts from byte zero")
    BEHAVIOR["v"] = "ok"

    # 5. oversize .part -> discarded, full re-download
    dest = fresh_dest(tmp, "s5")
    with open(dest + ".part", "wb") as f:
        f.write(DATA + b"x")
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(len(HITS) == 1 and HITS[0][1] == 200
           and open(dest, "rb").read() == DATA,
           "oversize .part discarded and re-fetched")

    # 6. complete valid .part -> adopted without network
    dest = fresh_dest(tmp, "s6")
    with open(dest + ".part", "wb") as f:
        f.write(DATA)
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(HITS == [] and open(dest, "rb").read() == DATA,
           "complete valid .part adopted offline")

    # 7. complete corrupt .part -> BootError, .part removed
    dest = fresh_dest(tmp, "s7")
    with open(dest + ".part", "wb") as f:
        f.write(DATA[:-1] + bytes([DATA[-1] ^ 0xFF]))
    HITS.clear()
    try:
        boot.download(url, dest, SHA, SIZE)
        expect(False, "corrupt .part must fail")
    except boot.BootError:
        pass
    expect(HITS == [] and not os.path.exists(dest + ".part"),
           "complete corrupt .part rejected and removed without network")

    # 8. flaky network (CAP bytes per request) -> in-process retries succeed
    BEHAVIOR["v"] = "flaky"
    dest = fresh_dest(tmp, "s8")
    HITS.clear()
    boot.download(url, dest, SHA, SIZE)
    expect(len(HITS) == 3 and [h[2] for h in HITS] == [0, CAP, 2 * CAP]
           and open(dest, "rb").read() == DATA,
           "flaky network: 3 attempts resume 0->CAP->2CAP and succeed")

    # 9. attempts exhausted -> BootError keeps .part; next call (fresh
    #    bootstrap run, like a systemd restart) resumes it to success
    dest = fresh_dest(tmp, "s9")
    boot.DOWNLOAD_ATTEMPTS = 2
    HITS.clear()
    try:
        boot.download(url, dest, SHA, SIZE)
        expect(False, "exhausted attempts must fail")
    except boot.BootError:
        pass
    kept = os.path.getsize(dest + ".part")
    boot.DOWNLOAD_ATTEMPTS = 3
    boot.download(url, dest, SHA, SIZE)
    expect(kept == 2 * CAP and len(HITS) == 3 and HITS[-1][2] == 2 * CAP
           and open(dest, "rb").read() == DATA,
           "exhausted run keeps .part; next run resumes from it")

    srv.shutdown()
    shutil.rmtree(tmp, ignore_errors=True)
    print("OK: all download resume scenarios passed")


if __name__ == "__main__":
    main()
