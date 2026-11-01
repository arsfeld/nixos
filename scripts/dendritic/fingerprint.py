#!/usr/bin/env python3
"""Compare NixOS system derivations with this flake's own source normalized away.

  fingerprint.py hash [--loose] <drv> < graph.json
  fingerprint.py explain [--loose] <graphA.json> <drvA> <graphB.json> <drvB>

graph.json is `nix derivation show -r <drv>` (zstd-compressed if it ends in .zst).

The graph is rehashed bottom-up. In every string, the self source path becomes
SELF, every derivation output path becomes a placeholder named by its producer's
canonical hash, and the flake registry's `self` entry (narHash, rev,
lastModified) becomes a constant. Two evaluations that differ only in which
commit of this flake produced them hash identically.

--loose additionally sorts the whitespace/colon/comma-separated tokens of every
string, so a pure reordering (e.g. systemPackages or kernelParams merged in a
different module order) hashes identically. It also masks reorderings that DO
matter (PATH precedence, a repeated kernel parameter), so a loose-only match
must be read with `explain` before it is accepted.

`explain` prints the derivations whose own content differs while all their
inputs match (the leaves of the change), with the differing fields.
"""
import hashlib, json, re, subprocess, sys

SELF_ENTRY = re.compile(r'\{"exact":true,"from":\{"id":"self","type":"indirect"\},"to":\{[^{}]*\}\}')
SELF_PATH = re.compile(r'"id":"self","type":"indirect"\},"to":\{[^{}]*"path":"(/nix/store/[^"]+)"')
STORE = re.compile(r"/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+")
TOKENS = re.compile(r"[\s:,]+")


def full(p):
    return p if p.startswith("/nix/store/") else "/nix/store/" + p


def load(src):
    if src == "-":
        raw = sys.stdin.buffer.read()
    elif src.endswith(".zst"):
        raw = subprocess.run(["zstd", "-dc", src], check=True, capture_output=True).stdout
    else:
        raw = open(src, "rb").read()
    g = json.loads(raw)
    g = g.get("derivations", g)
    return {full(k): v for k, v in g.items()}


class Canon:
    def __init__(self, graph, loose):
        self.graph, self.loose = graph, loose
        found = {m.group(1) for d in graph.values() for v in d.get("env", {}).values() for m in SELF_PATH.finditer(v)}
        if len(found) != 1:
            sys.exit(f"expected exactly one self source path in the flake registry, found {sorted(found)}")
        self.out_map = {found.pop(): "SELF"}
        self.hash, self.body = {}, {}

    def scrub(self, s):
        s = SELF_ENTRY.sub("SELF_REGISTRY_ENTRY", s)
        s = STORE.sub(lambda m: self.out_map.get(m.group(0), m.group(0)), s)
        return " ".join(sorted(TOKENS.split(s))) if self.loose else s

    def visit(self, path):
        if path in self.hash:
            return self.hash[path]
        d = self.graph[path]
        drvs = d.get("inputDrvs") or d.get("inputs", {}).get("drvs", {})
        srcs = d.get("inputSrcs") or d.get("inputs", {}).get("srcs", [])
        deps = sorted(
            (self.visit(full(p)), sorted(s["outputs"] if isinstance(s, dict) else s)) for p, s in drvs.items()
        )
        outs = {n: o["path"] for n, o in d.get("outputs", {}).items() if o.get("path")}
        body = {
            "name": d.get("name"),
            "deps": deps,
            "srcs": sorted(self.scrub(full(s)) for s in srcs),
            "builder": self.scrub(d["builder"]),
            "args": [self.scrub(a) for a in d["args"]],
            "env": {k: self.scrub(v) for k, v in sorted(d["env"].items()) if k not in outs},
            "outputs": sorted(outs),
        }
        h = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        self.hash[path], self.body[h] = h, body
        for n, p in outs.items():
            self.out_map[full(p)] = f"OUT[{h[:16]}:{n}]"
        return h


def main(argv):
    sys.setrecursionlimit(1_000_000)
    loose = "--loose" in argv
    argv = [a for a in argv if a != "--loose"]
    if argv and argv[0] == "hash":
        c = Canon(load("-"), loose)
        print(c.visit(full(argv[1])))
    elif argv and argv[0] == "explain":
        a, b = Canon(load(argv[1]), loose), Canon(load(argv[3]), loose)
        a.visit(full(argv[2]))
        b.visit(full(argv[4]))
        known = set(a.body)
        by_name = {}
        for body in a.body.values():
            by_name.setdefault(body["name"], []).append(body)
        for h, body in b.body.items():
            if h in known or any(dep not in known for dep, _ in body["deps"]):
                continue
            print(f"== {body['name']}")
            olds = by_name.get(body["name"], [])
            if len(olds) != 1:
                print(f"   (no unique counterpart: {len(olds)} derivations named {body['name']} before)")
                continue
            old = olds[0]
            for field in ("builder", "args", "srcs", "outputs"):
                if old[field] != body[field]:
                    print(f"   {field}: {old[field]!r} -> {body[field]!r}")
            for k in sorted(set(old["env"]) | set(body["env"])):
                if old["env"].get(k) != body["env"].get(k):
                    print(f"   env.{k}:\n     - {old['env'].get(k)!r:.600}\n     + {body['env'].get(k)!r:.600}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
