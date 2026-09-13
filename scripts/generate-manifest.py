#!/usr/bin/env python3
"""Render manifests/components.json for one arch from packaging/payload pins.

Usage:
  generate-manifest.py --pins packaging/payload/component-pins.json \
      --version 0.0.2 --arch x86_64 --out dist/.../manifests/components.json
      [--allow-pending]

A null sha256/size in the pins file means "not verified yet"; emission is
refused unless --allow-pending (and the first-start bootstrap always refuses
null hashes, so a pending manifest can never fetch).
"""
import argparse
import json
import re
import sys

SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def fail(msg: str) -> None:
    print(f"generate-manifest: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pins", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--arch", required=True, choices=["x86_64", "aarch64"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--allow-pending", action="store_true")
    args = ap.parse_args()

    pins = json.load(open(args.pins, encoding="utf-8"))
    rt = pins["runtime"]["targets"][args.arch]
    ag = pins["agent"]

    pending = []
    for label, comp in (("runtime", rt), ("agent", ag)):
        for field in ("sha256", "size"):
            if comp.get(field) is None:
                pending.append(f"{label}.{field}")
            elif field == "sha256" and not SHA_RE.match(str(comp["sha256"])):
                fail(f"{label}.sha256 malformed: {comp['sha256']!r}")
    if pending and not args.allow_pending:
        fail("pending unverified fields (null): " + ", ".join(pending) +
             "; verify hashes before emitting, or pass --allow-pending")

    manifest = {
        "schema": 1,
        "app_version": args.version,
        "arch": args.arch,
        "release_base": "https://github.com/Moechz/hermeswebui/releases/download/v" + args.version,
        "webui": {
            "tag": pins["webui"]["tag"],
            "version": pins["webui"]["version"],
            "date": pins["webui"]["date"],
        },
        "runtime": {
            "python": pins["runtime"]["python"],
            "pbs_tag": pins["runtime"]["pbs_tag"],
            "file": rt["file"],
            "sha256": rt["sha256"],
            "size": rt["size"],
            "dest": "runtime/python",
        },
        "agent": {
            "version": ag["version"],
            "tag": ag["tag"],
            "file": ag["file"],
            "sha256": ag["sha256"],
            "size": ag["size"],
            "dest": "hermes/hermes-agent",
        },
        # Keep in sync with packaging/templates/components.json.in (pip
        # block is literal there; verified by device measurement 2026-09-13:
        # TUNA ~700KB/s vs PyPI ~25KB/s on the target market network).
        "pip": {
            "index_url": "https://pypi.tuna.tsinghua.edu.cn/simple",
            "fallback_index_url": "https://pypi.org/simple",
        },
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    state = "PENDING(" + ",".join(pending) + ")" if pending else "verified"
    print(f"wrote {args.out} [{args.arch} {state}]")


if __name__ == "__main__":
    main()
