#!/usr/bin/env python3
"""Regression gate: our nginx route must not break upstream's CSRF gate.

Background (seq -015, user-reported on the store build): the TOS gateway
serves the WebUI route on a NON-default port (https://<tos>:5443/hermesagent/,
http://<tos>:8181/hermesagent/). Browsers therefore send

    Origin: https://192.168.1.50:5443

Upstream hermes-webui rejects any browser POST/PUT/DELETE whose Origin
host:port does not match the Host header it sees, answering 403
{"error": "Cross-origin mismatch - check reverse proxy headers"}
(api/routes.py:_check_same_origin_browser_request). The onboarding probe
caller then reports that detail under the "unreachable" heading, so the user
saw "Could not reach the configured base URL. (Cross-origin mismatch ...)" —
a made-up provider problem, while really every POST to the WebUI was blocked.

`proxy_set_header Host $host;` strips the port, so Origin (:5443) != Host
(:443 implied) -> 403. `$http_host` forwards the header verbatim and matches.

This test simulates nginx's expansion of the Host value our template uses,
feeds the result plus the browser Origin into the REAL upstream gate, and
asserts:
  1. the template's expression passes for every realistic TOS access shape;
  2. the stripped-port shape fails (so the test would catch a regression —
     and documents why the rule exists).

Stdlib only (imports the upstream checkout that the build already pins).
Use: python3 scripts/test-nginx-same-origin.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
NGINX = os.path.join(ROOT, "packaging", "templates",
                     "hermesagent-nginx.conf")
UPSTREAM = os.path.join(ROOT, "upstream", "hermes-webui")

# (browser Host header, matching Origin). Port 443/80 are omitted by browsers
# on default ports; TOS mgmt + gateway ports are non-default on purpose.
REQUESTS = [
    ("192.168.1.50:5443", "https://192.168.1.50:5443"),
    ("192.168.1.50:8181", "http://192.168.1.50:8181"),
    ("nas.example.com:5443", "https://nas.example.com:5443"),
    ("nas.example.com", "https://nas.example.com"),
    ("192.168.1.50", "http://192.168.1.50"),
]


class FakeHandler:
    def __init__(self, host, origin):
        self.headers = {
            "Host": host,
            "Origin": origin,
            "Sec-Fetch-Site": "same-origin",
        }


def nginx_host_value(template):
    """Extract the variable the template feeds to proxy_set_header Host."""
    found = re.findall(r"proxy_set_header\s+Host\s+([^;]+);", template)
    assert len(found) == 1, f"expected exactly one Host header, got {found!r}"
    value = found[0].strip()
    assert value.startswith("$"), f"Host value {value!r} is not a variable"
    return value


def expand(value, request_host):
    """Simulate nginx variable expansion for a request.

    $http_host  -> raw Host request header, verbatim (port included)
    $host       -> lowercase host name only (port, if any, stripped)
    $server_port/$server_name are intentionally NOT emulated: they expand from
    nginx's own server block, not from the client, so they cannot be assumed
    to equal the port the browser used (and the template must not use them).
    """
    if value == "$http_host":
        return request_host
    if value == "$host":
        host = request_host.rsplit(":", 1)[0] if ":" in request_host \
            else request_host
        return host.lower()
    raise AssertionError(
        f"unsupported Host expression {value!r}: the template must use "
        "$http_host so the browser-visible host:port reaches the app")


def load_gate():
    sys.path.insert(0, UPSTREAM)
    from api import routes  # noqa: E402  (heavy import, only for the gate)
    return routes


def main():
    template = open(NGINX, encoding="utf-8").read()
    value = nginx_host_value(template)
    print(f"nginx Host expression: {value}")

    try:
        routes = load_gate()
    except Exception as exc:  # upstream checkout absent / unimportable
        print(f"SKIP: cannot import upstream api.routes ({exc.__class__.__name__}: "
              f"{exc}); template rule checked by validate-package.sh")
        print("OK: (static checks only)")
        return

    for request_host, origin in REQUESTS:
        forwarded = expand(value, request_host)
        handler = FakeHandler(forwarded, origin)
        if not routes._check_same_origin_browser_request(handler):
            raise AssertionError(
                f"BLOCKED: Origin {origin} vs forwarded Host {forwarded!r} -> "
                f"{routes._csrf_rejection_error(handler)}")
        print(f"PASS: Origin {origin} vs Host {forwarded!r} allowed")

    # Teeth: prove the pre-seq-015 shape really was rejected, so this test
    # fails if someone reverts the template to a port-stripping expression.
    stripped = expand("$host", "192.168.1.50:5443")
    handler = FakeHandler(stripped, "https://192.168.1.50:5443")
    allowed = routes._check_same_origin_browser_request(handler)
    assert not allowed, "expected the port-stripping shape to be rejected"
    assert routes._csrf_rejection_error(handler) == \
        "Cross-origin mismatch - check reverse proxy headers", \
        routes._csrf_rejection_error(handler)
    print(f"PASS: port-stripping shape still rejected ({stripped!r} vs :5443) "
          "- regression guard has teeth")

    print("OK: all nginx same-origin scenarios passed")


if __name__ == "__main__":
    main()
