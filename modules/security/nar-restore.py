"""Unpack a NAR from stdin into the path named by argv[1].

Unlike `nix-store --restore`, this does not insist that directory entries
arrive sorted. replaceDirectDependencies rewrites store hashes inside the NAR
stream, and a hash that is part of an entry *name* (gstreamer's
share/gdb/auto-load/nix/store/<hash>-gstreamer-*, merged into an FHS rootfs)
can reorder siblings. The bytes are otherwise exactly what --restore would
have written; Nix canonicalises permissions when it registers the output.
"""

import os
import sys

f = sys.stdin.buffer


def read_int():
    b = f.read(8)
    if len(b) != 8:
        raise EOFError("truncated NAR")
    return int.from_bytes(b, "little")


def skip_padding(n):
    pad = (8 - n % 8) % 8
    if f.read(pad) != b"\0" * pad:
        raise ValueError("bad NAR padding")


def read_str():
    n = read_int()
    s = f.read(n)
    if len(s) != n:
        raise EOFError("truncated NAR")
    skip_padding(n)
    return s


def expect(token):
    s = read_str()
    if s != token:
        raise ValueError(f"expected {token!r}, got {s!r}")


def regular(path):
    executable = False
    tag = read_str()
    if tag == b"executable":
        expect(b"")
        executable = True
        tag = read_str()
    if tag != b"contents":
        raise ValueError(f"expected contents, got {tag!r}")
    remaining = n = read_int()
    with open(path, "wb") as out:
        while remaining:
            chunk = f.read(min(remaining, 1 << 20))
            if not chunk:
                raise EOFError("truncated NAR")
            out.write(chunk)
            remaining -= len(chunk)
    skip_padding(n)
    if executable:
        os.chmod(path, 0o755)


def directory(path):
    os.mkdir(path)
    while True:
        tag = read_str()
        if tag == b")":
            return
        if tag != b"entry":
            raise ValueError(f"expected entry, got {tag!r}")
        expect(b"(")
        expect(b"name")
        name = read_str()
        if name in (b"", b".", b"..") or b"/" in name or b"\0" in name:
            raise ValueError(f"bad entry name {name!r}")
        expect(b"node")
        node(os.path.join(path, name))
        expect(b")")


def node(path):
    expect(b"(")
    expect(b"type")
    kind = read_str()
    if kind == b"regular":
        regular(path)
    elif kind == b"symlink":
        expect(b"target")
        os.symlink(read_str(), path)
    elif kind == b"directory":
        directory(path)
        return  # directory() consumed the closing ")"
    else:
        raise ValueError(f"unknown node type {kind!r}")
    expect(b")")


expect(b"nix-archive-1")
node(os.fsencode(sys.argv[1]))
if f.read(1):
    raise ValueError("trailing data after NAR")
