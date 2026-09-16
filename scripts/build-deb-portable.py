#!/usr/bin/env python3
"""Portable .deb builder for macOS verification builds.

A .deb is an `ar` archive with three members: debian-binary (2.0),
control.tar.gz (DEBIAN/*) and data.tar.xz (the filesystem tree).
Python's stdlib can produce all of them byte-correctly, which lets us
build installable verification debs on machines without dpkg-deb.

This mimics `dpkg-deb --root-owner-group --no-uniform-compression -Zxz`:
  - ar member headers in dpkg style (name + '/', mtime 0, 0/0, mode 644)
  - control.tar.gz with zeroed gzip mtime; control 0644, scripts 0755
  - data.tar.xz (GNU tar format, xz preset 6 / CRC64), uid/gid 0,
    uname/gname root, file mtimes preserved
  - DEBIAN/ excluded from data.tar (dpkg-deb rule)

RELEASE BUILDS MUST STILL COME FROM A LINUX dpkg-deb ENVIRONMENT
(AGENTS.md 9) — this exists for manual-install verification only.

Usage: build-deb-portable.py <tree> <out.deb>
"""
import gzip
import io
import lzma
import os
import stat
import sys
import tarfile


def ar_header(name: str, size: int) -> bytes:
    # dpkg-deb style: short name with trailing '/', mtime 0, uid/gid 0,
    # mode 0644, decimal size, backtick-newline magic.
    h = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{size:<10}".encode()
    return h + b"`\n"


def ar_member(name: str, data: bytes) -> bytes:
    out = ar_header(name, len(data)) + data
    if len(data) % 2:  # members are 2-byte aligned, '\n' padded
        out += b"\n"
    return out


def tar_bytes(paths, gnu=True):
    """paths: list of (abs_path, arcname, explicit_mode_or_None)."""
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT)
    for src, arc, mode in paths:
        st = os.lstat(src)
        ti = tf.gettarinfo(src, arcname=arc)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        if mode is not None:
            ti.mode = mode
        if stat.S_ISDIR(st.st_mode):
            ti.type = tarfile.DIRTYPE
            tf.addfile(ti)
        elif stat.S_ISLNK(st.st_mode):
            tf.addfile(ti)  # symlink, no data
        elif stat.S_ISREG(st.st_mode):
            with open(src, "rb") as f:
                tf.addfile(ti, f)
        else:
            raise SystemExit(f"unsupported file type: {src}")
    tf.close()
    return buf.getvalue()


def walk(root: str):
    """Deterministic (dirs first, lexical) walk yielding (path, rel)."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            out.append((dirpath, rel))
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            out.append((p, os.path.relpath(p, root)))
    return out


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    tree, out = sys.argv[1:3]

    debian = os.path.join(tree, "DEBIAN")
    if not os.path.isdir(debian):
        raise SystemExit(f"no DEBIAN dir in {tree}")

    # control.tar.gz ---------------------------------------------------
    cpaths = []
    for name in sorted(os.listdir(debian)):
        p = os.path.join(debian, name)
        mode = 0o755 if os.access(p, os.X_OK) else 0o644
        cpaths.append((p, name, mode))
    control_tgz = gzip.compress(tar_bytes(cpaths), mtime=0)

    # data.tar.xz -------------------------------------------------------
    dpaths = [(p, rel, None) for p, rel in walk(tree) if rel != "DEBIAN"
              and not rel.startswith("DEBIAN" + os.sep)]
    data_xz = lzma.compress(tar_bytes(dpaths), format=lzma.FORMAT_XZ,
                            preset=6 | lzma.PRESET_EXTREME)

    # ar container ------------------------------------------------------
    deb = bytearray(b"!<arch>\n")
    deb += ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.gz", control_tgz)
    deb += ar_member("data.tar.xz", data_xz)

    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(deb)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, out)
    print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
