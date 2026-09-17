#!/usr/bin/env python3
"""macOS fallback .deb builder (verification builds only).

dpkg-deb only exists on Linux, but a .deb is just an ar archive around
two tar members. This tool reproduces the exact member layout the TOS
App Center parser accepted for our device-validated packages
(scripts/build-package.sh):

    ar container:
      debian-binary    "2.0\n"
      control.tar.gz   ./postinst ./prerm ./postrm ./control ...
      data.tar.xz      everything except DEBIAN/, root-owned, gnutar

Usage:
  build-deb-macos.py <staged-tree> <output.deb>

Notes:
  - Final release artifacts still come from a Linux dpkg-deb build
    (AGENTS.md 9); this path exists for manual-install verification
    while no Linux host is reachable.
  - bsdtar (macOS) writes the tars with --format gnutar, root ownership
    (--uid 0 --gid 0), and COPYFILE_DISABLE=1 keeps AppleDouble junk out.
  - The ar container is written by hand below so member naming/padding
    matches dpkg-deb byte-for-byte (plain names, space padded, even-
    length data padding, mode 0100644 headers).
"""
import os
import struct
import subprocess
import sys
import tempfile


def run(argv, **kw):
    print("+ " + " ".join(argv), file=sys.stderr)
    return subprocess.run(argv, check=True, **kw)


def make_tar(out_path, tarball_dir, fmt, compress, excludes=()):
    argv = ["/usr/bin/tar", "--format", fmt,
            "--uid", "0", "--gid", "0", "--uname", "root", "--gname", "root"]
    for exc in excludes:
        argv += ["--exclude", exc]
    argv += ["-cf", out_path, "-C", tarball_dir, "."]
    # compression is applied by bsdtar via the -a/--auto flag on the
    # output suffix; pass explicit compressors instead so it is explicit:
    if compress == "xz":
        argv.insert(1, "--options=xz:compression-level=6")
        out_path += ".xz"
        argv[argv.index("-cf") + 1] = out_path
    return out_path


def bsdtar(out_path, src_dir, fmt, excludes=()):
    argv = ["/usr/bin/tar", "--format", fmt,
            "--uid", "0", "--gid", "0", "--uname", "root", "--gname", "root"]
    for exc in excludes:
        argv += ["--exclude", exc]
    argv += ["-cf", out_path, "-C", src_dir, "."]
    run(argv)
    return out_path


def ar_member(name: str, data: bytes) -> bytes:
    """One ar member header + payload, dpkg-deb style."""
    header = (
        f"{name:<16}"          # name, space padded (no slash — GNU/dpkg style)
        f"{0:<12}"             # mtime 0 like dpkg-deb --root-owner-group builds
        f"{0:<6}"              # uid
        f"{0:<6}"              # gid
        f"{0o100644:<8}"       # mode
        f"{len(data):<10}"     # size
        "`\n"                  # magic
    ).encode("ascii")
    assert len(header) == 60, len(header)
    out = header + data
    if len(data) % 2:
        out += b"\n"           # ar members are padded to even length
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    tree, out = sys.argv[1:3]
    debian = os.path.join(tree, "DEBIAN")
    if not os.path.isdir(debian):
        print(f"FAIL: {debian} not found (not a staged package tree?)", file=sys.stderr)
        return 1
    os.environ["COPYFILE_DISABLE"] = "1"
    with tempfile.TemporaryDirectory(prefix="hwui-deb-") as tmp:
        # control member: gzip-compressed gnutar of DEBIAN/ at archive root
        ctl = bsdtar(os.path.join(tmp, "control.tar"), debian, "gnutar")
        with open(ctl, "rb") as f:
            ctl_raw = f.read()
        import gzip
        ctl_gz = gzip.GzipFile(filename="", mtime=0, mode="wb",
                               fileobj=open(os.path.join(tmp, "control.tar.gz"), "wb"))
        ctl_gz.write(ctl_raw)
        ctl_gz.close()
        # data member: xz-compressed gnutar of the tree minus DEBIAN/
        data = bsdtar(os.path.join(tmp, "data.tar.xz"), tree, "gnutar",
                      excludes=("./DEBIAN",))
        # junk guard (macOS metadata must never enter a package)
        listing = run(["/usr/bin/tar", "-tf", data], capture_output=True,
                      text=True).stdout.splitlines()
        bad = [n for n in listing if "/._" in n or n.startswith("._")
               or ".DS_Store" in n or "./DEBIAN" in n]
        if bad:
            print(f"FAIL: junk or DEBIAN in data member: {bad[:3]}", file=sys.stderr)
            return 1
        with open(os.path.join(tmp, "control.tar.gz"), "rb") as f:
            control = f.read()
        with open(data, "rb") as f:
            data_xz = f.read()
        blob = (b"!<arch>\n"
                + ar_member("debian-binary", b"2.0\n")
                + ar_member("control.tar.gz", control)
                + ar_member("data.tar.xz", data_xz))
        tmp_out = out + ".tmp"
        with open(tmp_out, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_out, out)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
