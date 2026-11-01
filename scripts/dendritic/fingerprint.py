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
string and the elements of every structuredAttrs list, so a pure reordering (e.g. systemPackages or kernelParams merged in a
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
# A space-separated run of two or more output placeholders. Such runs come from
# lists nix built in store-path order (e.g. references.nix, which the brotli
# graft reads), and store paths change with every commit, so their order is
# noise: sort each run.
PLACEHOLDER_RUN = re.compile(r"(?:(?:OUT\[[0-9a-f]{16}:[^\]]+\]|SELF)[ ]){1,}(?:OUT\[[0-9a-f]{16}:[^\]]+\]|SELF)")


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


def strings(d):
    """Every string a derivation's env and structuredAttrs (nixpkgs-unstable) carry."""
    todo = list(d.get("env", {}).values()) + [d.get("structuredAttrs")]
    while todo:
        v = todo.pop()
        if isinstance(v, str):
            yield v
        elif isinstance(v, dict):
            todo.extend(v.values())
        elif isinstance(v, list):
            todo.extend(v)


class Canon:
    def __init__(self, graph, loose):
        self.graph, self.loose = graph, loose
        found = {m.group(1) for d in graph.values() for v in strings(d) for m in SELF_PATH.finditer(v)}
        if len(found) != 1:
            sys.exit(f"expected exactly one self source path in the flake registry, found {sorted(found)}")
        self.self_path = found.pop()
        self.prev_map = {}

    def run(self, top):
        """Canonicalize until the output-path map stops changing.

        A string can name an output whose producer is not among the
        derivation's inputs, so a depth-first pass may meet the path before
        its producer: replaceDependencies (the brotli graft) finds the paths
        to rewrite by import-from-derivation. Later passes read placeholders
        the previous pass assigned."""
        for _ in range(10):
            self.out_map = {self.self_path: "SELF"}
            self.hash, self.body = {}, {}
            h = self.visit(top)
            if self.out_map == self.prev_map:
                return h
            self.prev_map = self.out_map
        sys.exit("output-path placeholders did not converge in 10 passes")

    def scrub(self, s):
        s = SELF_ENTRY.sub("SELF_REGISTRY_ENTRY", s)
        s = STORE.sub(lambda m: self.out_map.get(m.group(0)) or self.prev_map.get(m.group(0), m.group(0)), s)
        s = PLACEHOLDER_RUN.sub(lambda m: " ".join(sorted(m.group(0).split(" "))), s)
        return " ".join(sorted(TOKENS.split(s))) if self.loose else s

    def scrub_tree(self, v):
        if isinstance(v, str):
            return self.scrub(v)
        if isinstance(v, dict):
            return {k: self.scrub_tree(x) for k, x in sorted(v.items())}
        if isinstance(v, list):
            items = [self.scrub_tree(x) for x in v]
            # loose: a structuredAttrs list (buildEnv's paths, …) merged in a
            # different module order is the same multiset
            return sorted(items, key=lambda x: json.dumps(x, sort_keys=True)) if self.loose else items
        return v

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
            "env": {k: self.scrub(v) for k, v in sorted(d.get("env", {}).items()) if k not in outs},
            "structuredAttrs": self.scrub_tree(d.get("structuredAttrs")),
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
        print(c.run(full(argv[1])))
    elif argv and argv[0] == "explain":
        a, b = Canon(load(argv[1]), loose), Canon(load(argv[3]), loose)
        a.run(full(argv[2]))
        b.run(full(argv[4]))
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
            for field in ("builder", "args", "srcs", "outputs", "structuredAttrs"):
                if old[field] != body[field]:
                    print(f"   {field}: {old[field]!r} -> {body[field]!r}")
            for k in sorted(set(old["env"]) | set(body["env"])):
                if old["env"].get(k) != body["env"].get(k):
                    print(f"   env.{k}:\n     - {old['env'].get(k)!r:.600}\n     + {body['env'].get(k)!r:.600}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
