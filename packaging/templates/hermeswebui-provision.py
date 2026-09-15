#!/usr/bin/env python3
"""hermeswebui first-start provisioning placeholder page.

During first-start provisioning (D-007: components are fetched at first
service start, never in lifecycle scripts) the real WebUI is not running
yet, so port 8787 answers nothing and users see "connection refused" —
indistinguishable from a broken app (user-reported). This tiny stdlib-only
server binds the port FIRST and serves a bilingual progress page until the
launcher hands over to the real WebUI.

It runs on the TOS system Python (/usr/bin/python3), never touches the
network except for serving this page, and exits when the launcher kills it.

Rendered progress sources (all optional; the page degrades gracefully):
  - /var/lib/hermeswebui/bootstrap/state.json   completed stage marks
  - /var/lib/hermeswebui/downloads/*.part       in-flight download bytes
  - /usr/local/hermeswebui/manifests/components.json   expected sizes
  - /var/lib/hermeswebui/bootstrap/last.log     previous attempt tail
"""

import glob
import html
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get("HERMES_WEBUI_STATE_ROOT", "/var/lib/hermeswebui")
APP_HOME = os.environ.get("HERMES_WEBUI_APP_HOME", "/usr/local/hermeswebui")
PORT = int(os.environ.get("HERMES_WEBUI_PORT", "8787"))
HOST = os.environ.get("HERMES_WEBUI_HOST", "0.0.0.0")

STAGES = [
    ("runtime", "下载 Python 运行时 / Downloading Python runtime"),
    ("app_venv", "准备应用环境 / Preparing application environment"),
    ("agent_src", "下载 Hermes Agent / Downloading Hermes Agent"),
    ("agent_deps", "安装依赖（清华镜像） / Installing dependencies (TUNA)"),
    ("lazy_extras", "安装可选组件 / Installing optional components"),
    ("agent_editable", "收尾 / Finalizing"),
]


def _marks():
    try:
        with open(os.path.join(STATE, "bootstrap", "state.json"),
                  encoding="utf-8") as fh:
            return set(json.load(fh))
    except Exception:
        return set()


def _expected_sizes():
    sizes = {}
    try:
        with open(os.path.join(APP_HOME, "manifests", "components.json"),
                  encoding="utf-8") as fh:
            m = json.load(fh)

        def _add(entry):
            if isinstance(entry, dict) and entry.get("file"):
                sizes[entry["file"]] = int(entry.get("size") or 0)

        rt = m.get("runtime") or {}
        if isinstance(rt.get("targets"), dict):
            for t in rt["targets"].values():
                _add(t)
        else:
            _add(rt)
        _add(m.get("agent"))
    except Exception:
        pass
    return sizes


def _progress():
    """Return (done_count, total, label, dl_percent, dl_text, log_tail)."""
    marks = _marks()
    done = sum(1 for key, _ in STAGES if key in marks)
    label = STAGES[min(done, len(STAGES) - 1)][1]
    expected = _expected_sizes()
    dl_percent, dl_text = None, ""
    parts = sorted(glob.glob(os.path.join(STATE, "downloads", "*.part")))
    if parts and expected:
        name = os.path.basename(parts[0])[:-len(".part")]
        total = expected.get(name, 0)
        try:
            got = os.path.getsize(parts[0])
        except OSError:
            got = 0
        if total > 0:
            dl_percent = min(100.0, got * 100.0 / total)
            dl_text = "%.1f / %.1f MB" % (got / 1e6, total / 1e6)
    log_tail = ""
    try:
        with open(os.path.join(STATE, "bootstrap", "last.log"),
                  encoding="utf-8", errors="replace") as fh:
            log_tail = html.escape("".join(fh.readlines()[-6:]).strip())
    except Exception:
        pass
    return done, len(STAGES), label, dl_percent, dl_text, log_tail


PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="3">
<title>%(title)s</title>
<style>
 body{font-family:system-ui,-apple-system,"Segoe UI","PingFang SC",
      "Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;
      display:flex;align-items:center;justify-content:center;
      min-height:100vh;margin:0}
 .card{max-width:640px;padding:40px 44px;background:#171a21;
       border:1px solid #2a2f3a;border-radius:14px}
 h1{font-size:20px;margin:0 0 6px}
 p.sub{color:#9aa3b2;margin:0 0 26px;font-size:14px}
 .bar{height:10px;background:#252a35;border-radius:6px;overflow:hidden}
 .fill{height:100%%;background:linear-gradient(90deg,#4f8cff,#7cc4ff);
       border-radius:6px;transition:width .8s}
 .ind{width:45%%;background:#2a3140;animation:pulse 1.4s infinite}
 @keyframes pulse{50%%{opacity:.45}}
 .stage{margin:14px 0 4px;font-size:15px}
 .detail{color:#8b93a3;font-size:13px;margin:2px 0 0}
 .note{margin-top:26px;color:#7c8598;font-size:12.5px;line-height:1.7;
       border-top:1px solid #262b36;padding-top:16px}
 pre{background:#10131a;border:1px solid #262b36;border-radius:8px;
     padding:10px;font-size:11.5px;overflow:auto;color:#e08c8c;
     white-space:pre-wrap;margin:14px 0 0}
</style>
</head>
<body>
<div class="card">
 <h1>%(title)s</h1>
 <p class="sub">首次启动需要从网络装配运行组件，本页每 3 秒自动刷新。<br>
 First start downloads runtime components; this page refreshes itself.</p>
 <div class="stage">%(stage)s</div>
 <div class="bar"><div class="fill %(cls)s" style="width:%(width)s"></div></div>
 <p class="detail">%(detail)s · %(done)s/%(total)s</p>
 <div class="note">
  慢网络下整个过程可能需要 10–20 分钟，请不要关闭本页；完成后会自动进入应用。<br>
  On slow networks this can take 10–20 minutes. The app opens automatically
  when ready. 进度日志 / log: <code>/var/lib/hermeswebui/bootstrap/last.log</code>
 </div>
%(log_html)s
</div>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self._page(head=True)

    def do_GET(self):
        self._page(head=False)

    def _page(self, head):
        try:
            done, total, label, pct, dl_text, log_tail = _progress()
        except Exception:
            done, total, label, pct, dl_text, log_tail = (
                0, len(STAGES), STAGES[0][1], None, "", "")
        if pct is None:
            width, cls = "45%", "ind"
            detail = "进行中 / working"
        else:
            width, cls = "%.1f%%" % pct, ""
            detail = "下载中 / downloading %s (%.0f%%)" % (dl_text, pct)
        body = PAGE % {
            "title": "Hermes Agent WebUI — 首次装配中 / Provisioning",
            "stage": html.escape(label),
            "width": width,
            "cls": cls,
            "detail": detail,
            "done": done,
            "total": total,
            "log_html": (
                "<pre>%s</pre>" % log_tail) if log_tail else "",
        }
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def log_message(self, fmt, *args):  # keep journal quiet (3s refresh)
        return


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print("[provision] placeholder listening on %s:%d" % (HOST, PORT),
          flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
