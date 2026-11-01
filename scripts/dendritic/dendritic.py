#!/usr/bin/env python3
"""Mechanical helpers for the dendritic restructure. Run from the repo root.

  dendritic.py reach <dir>
      List .nix files under <dir> that its configuration.nix (plus
      disko-config.nix) never imports as a module, following bare relative
      entries of `imports` lists. import-tree would load each listed file as a
      module, so each must get a leading `_` (or be deleted) first. IMPORTS
      lines flag imports lists that are not plain literals.

  dendritic.py unwith FILE...
      Delete `with lib;` from each file and prefix with `lib.` every name it
      was supplying, found by parsing until nothing is undefined. Scoped forms
      like `with lib.kernel;` are not touched. Run from the repo root (it
      reads the lib attribute names from this flake's nixpkgs input).

  dendritic.py hide <dir>
      `git mv` every file `reach` lists to a `_`-prefixed name, and rewrite
      the relative path literals inside <dir> that pointed at it. References
      from outside <dir> (flake checks, tests) are left for a grep.

  dendritic.py fixpaths <old-root> <new-root>
      After `git mv <old-root> <new-root>`: rewrite every relative path literal
      in <new-root>'s .nix files that pointed outside the old root, so it still
      resolves to the same file from the new location.

  dendritic.py checkpaths FILE...
      Print every relative path literal in FILEs that no longer resolves
      (after a `git mv`); exit 1 if any. Literals inside shell strings are
      reported too and can be ignored when they are not Nix paths.

  dendritic.py wrap --root <dir> --into <attrpath> [--key <key>] FILE...
      Rewrite NixOS module files in place as flake-parts modules defining
      <attrpath>. Leading comments stay on top. `self` and `inputs` move from
      the module's argument pattern to the flake-parts module's. Bare relative
      entries of imports lists are dropped, because import-tree loads those
      files itself; only entries resolving inside --root count. With --key the value is {key; imports = [<module>];}, so a
      feature imported from several places is loaded once: flake-parts sets no
      key itself, and without one a second import redeclares every option.
      Files it cannot handle are reported as SKIPPED and left untouched.
"""
import argparse, json, os, re, subprocess, sys

SPECIAL = ("self", "inputs")
PATH = r"\.\.?/[A-Za-z0-9_./+-]*"
BARE = re.compile(rf"^\s*({PATH})\s*(#.*)?$")
OPEN = re.compile(r"^(\s*)imports\s*=\s*\[\s*(#.*)?$")
ONE_LINE = re.compile(r"^(\s*)imports\s*=\s*\[(.*)\];\s*(#.*)?$")
ANY_IMPORTS = re.compile(r"^\s*imports\s*=")
PATTERN = re.compile(r"^\{([^{}]*)\}\s*(@\s*[A-Za-z_][A-Za-z0-9_'-]*\s*)?:")
LEFTOVER = re.compile(r"\{[^{}]*\b(self|inputs)\b[^{}]*\}\s*:")


def import_lists(lines):
    """Yield (kind, start, end, bare_paths) for each imports list.

    kind is "multi" (lines start..end inclusive), "one" (a single line), or
    "odd" (an `imports =` this reader does not understand)."""
    i = 0
    while i < len(lines):
        line = lines[i]
        m1, m2 = OPEN.match(line), ONE_LINE.match(line)
        if m1:
            close = re.compile(rf"^{re.escape(m1.group(1))}\];")
            j = i + 1
            while j < len(lines) and not close.match(lines[j]):
                j += 1
            bare = [BARE.match(l).group(1) for l in lines[i + 1 : j] if BARE.match(l)]
            yield "multi", i, j, bare
            i = j
        elif m2:
            items = m2.group(2).split()
            bare = [t for t in items if re.fullmatch(PATH, t)]
            # all local, or none local (kept as is); a mix needs a human
            yield ("one" if len(bare) in (0, len(items)) else "odd"), i, i, bare
        elif ANY_IMPORTS.match(line):
            yield "odd", i, i, []
        i += 1


def reach(root):
    root = os.path.normpath(root)
    todo = [os.path.join(root, f) for f in ("configuration.nix", "disko-config.nix")]
    todo = [t for t in todo if os.path.exists(t)]
    reached, odd = set(), []
    while todo:
        f = todo.pop()
        if f in reached:
            continue
        reached.add(f)
        lines = open(f).read().splitlines()
        for kind, s, _, bare in import_lists(lines):
            if kind == "odd":
                odd.append(f"{f}:{s + 1}: {lines[s].strip()}")
            for p in bare:
                target = os.path.normpath(os.path.join(os.path.dirname(f), p))
                if os.path.isdir(target):
                    target = os.path.join(target, "default.nix")
                if target.startswith(root + os.sep) and target.endswith(".nix"):
                    todo.append(target)
    unreached = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(dirpath, name)
            if name.endswith(".nix") and path not in reached and "/_" not in path[len(root) :]:
                unreached.append(path)
    return unreached, odd


LITERAL = re.compile(rf"(?<![\w/.$}}-])({PATH})")


def rewrite_literals(root, resolve):
    """Rewrite relative path literals in root's .nix files.

    resolve(dirpath, literal) returns the absolute target the literal must keep
    pointing at, or None to leave it alone."""
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".nix"):
                continue
            path = os.path.join(dirpath, name)

            def repl(m):
                target = resolve(dirpath, m.group(1))
                if target is None:
                    return m.group(1)
                new = os.path.relpath(target, dirpath)
                return new if new.startswith(".") else "./" + new

            text = open(path).read()
            new_text = LITERAL.sub(repl, text)
            if new_text != text:
                open(path, "w").write(new_text)
                print(f"rewrote   {path}")


def fixpaths(old_root, new_root):
    old_root, new_root = os.path.abspath(old_root), os.path.abspath(new_root)

    def resolve(dirpath, lit):
        old_dir = os.path.join(old_root, os.path.relpath(dirpath, new_root))
        target = os.path.normpath(os.path.join(old_dir, lit))
        return None if target == old_root or target.startswith(old_root + os.sep) else target

    rewrite_literals(new_root, resolve)


def checkpaths(files):
    """Print relative path literals that do not resolve. Returns the count."""
    bad = 0
    for path in files:
        text = re.sub(r"#[^\n]*", "", open(path).read())
        for m in LITERAL.finditer(text):
            target = os.path.normpath(os.path.join(os.path.dirname(path), m.group(1)))
            if not os.path.exists(target):
                bad += 1
                print(f"DANGLING  {path}: {m.group(1)}")
    return bad


def hide(root):
    """git mv every unreached file to a `_` name and repoint references inside root."""
    root = os.path.abspath(root)
    unreached, odd = reach(root)
    moved = {}
    for path in unreached:
        # a directory imported for its default.nix is hidden as a whole
        if os.path.basename(path) == "default.nix":
            path = os.path.dirname(path)
        if any(path.startswith(m + os.sep) for m in moved):
            continue
        new = os.path.join(os.path.dirname(path), "_" + os.path.basename(path))
        subprocess.run(["git", "mv", path, new], check=True)
        moved[path] = new
        print(f"hid       {os.path.relpath(path)} -> {os.path.basename(new)}")

    def resolve(dirpath, lit):
        target = os.path.normpath(os.path.join(dirpath, lit))
        for old, new in moved.items():
            if target == old or target.startswith(old + os.sep):
                return new + target[len(old) :]
        return None

    rewrite_literals(root, resolve)
    for o in odd:
        print(f"IMPORTS   {o}")
    if moved:
        print("grep the rest of the repo for these names: references from outside this directory are not rewritten")


WITH_LIB = re.compile(r"\bwith lib;[ \t]*\n?[ \t]*")
UNDEFINED = re.compile(r"undefined variable '(.+)'\n\s+at (.+?):(\d+):(\d+)")


def unwith(path, lib_names):
    """Delete `with lib;` and prefix every name it supplied with `lib.`.

    Nix resolves variables when it parses, so `nix-instantiate --parse`
    names the first one left undefined; prefix it and parse again."""
    text = open(path).read()
    if not WITH_LIB.search(text):
        return 0
    text = WITH_LIB.sub("", text)
    fixes = 0
    while True:
        open(path, "w").write(text)
        r = subprocess.run(["nix-instantiate", "--parse", path], capture_output=True, text=True)
        if r.returncode == 0:
            return fixes
        m = UNDEFINED.search(r.stderr)
        if not m or m.group(1) not in lib_names:
            raise ValueError(r.stderr.strip().splitlines()[0])
        name, line, col = m.group(1), int(m.group(3)), int(m.group(4))
        lines = text.split("\n")
        raw = lines[line - 1].encode()
        at = col - 1  # nix reports a byte column
        assert raw[at : at + len(name)] == name.encode(), (path, line, col, name)
        lines[line - 1] = (raw[:at] + b"lib." + raw[at:]).decode()
        text = "\n".join(lines)
        fixes += 1


def split_header(text):
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].strip() == "" or lines[i].lstrip().startswith("#")):
        i += 1
    return "".join(lines[:i]), "".join(lines[i:]).strip()


def strip_specials(expr):
    if re.match(r"^[A-Za-z_][A-Za-z0-9_'-]*\s*@", expr):
        raise ValueError("argument pattern uses @; convert by hand")
    m = PATTERN.match(expr)
    if not m:
        return expr, []  # an attrset module, or a let/with before the function
    if m.group(2):
        raise ValueError("argument pattern uses @; convert by hand")
    args = [a.strip() for a in re.sub(r"#[^\n]*", "", m.group(1)).split(",") if a.strip()]
    names = [re.split(r"[\s?]", a, maxsplit=1)[0] for a in args]
    taken = [n for n in names if n in SPECIAL]
    kept = [a for a, n in zip(args, names) if n not in SPECIAL]
    if "..." not in kept:
        kept.append("...")
    return "{" + ", ".join(kept) + "}:" + expr[m.end() :], taken


def drop_local_imports(expr, filedir, root):
    """Drop imports entries that resolve inside root: import-tree loads those."""
    lines = expr.split("\n")
    drop = set()

    def inside(p):
        t = os.path.normpath(os.path.join(filedir, p))
        return t == root or t.startswith(root + os.sep)

    for kind, s, e, all_bare in import_lists(lines):
        bare = [p for p in all_bare if inside(p)]
        if kind == "odd":
            raise ValueError(f"imports list on line {s + 1} is not a plain literal; convert by hand")
        if kind == "one":
            if not bare:
                continue
            drop.add(s)
            rest = [t for t in lines[s][lines[s].index("[") + 1 : lines[s].rindex("]")].split() if t not in bare]
            if rest and bare:
                raise ValueError(f"one-line imports list on line {s + 1} mixes local and other entries")
        else:
            local = {k for k in range(s + 1, e) if BARE.match(lines[k]) and inside(BARE.match(lines[k]).group(1))}
            body = [k for k in range(s + 1, e) if k not in local]
            drop.update(local)
            if not any(lines[k].strip() and not lines[k].strip().startswith("#") for k in body):
                drop.update(range(s, e + 1))
    return "\n".join(l for k, l in enumerate(lines) if k not in drop)


def wrap(text, into, key, filedir, root):
    header, expr = split_header(text)
    expr, taken = strip_specials(expr)
    expr = drop_local_imports(expr, filedir, root)
    if re.fullmatch(r"(\{[^{}]*\}\s*:\s*)?\{\s*\}", expr.strip()):
        return None  # only imported its siblings, which import-tree now loads
    if LEFTOVER.search(expr):
        raise ValueError("a nested argument pattern still takes self/inputs; convert by hand")
    value = f'{{\n  key = "{key}";\n  imports = [\n({expr})\n];\n}}' if key else expr
    body = f"{{\n  {into} = {value};\n}}\n"
    if taken:
        body = "{" + ", ".join(taken + ["..."]) + "}: " + body
    return header + body


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("reach")
    r.add_argument("dir")
    h = sub.add_parser("hide")
    h.add_argument("dir")
    f = sub.add_parser("fixpaths")
    f.add_argument("old_root")
    f.add_argument("new_root")
    c = sub.add_parser("checkpaths")
    c.add_argument("files", nargs="+")
    u = sub.add_parser("unwith")
    u.add_argument("files", nargs="+")
    w = sub.add_parser("wrap")
    w.add_argument("--into", required=True)
    w.add_argument("--key")
    w.add_argument("--root", required=True, help="the tree import-tree loads; imports into it are dropped")
    w.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "reach":
        unreached, odd = reach(a.dir)
        for u in unreached:
            print(f"UNREACHED {u}")
        for o in odd:
            print(f"IMPORTS   {o}")
    elif a.cmd == "hide":
        hide(a.dir)
    elif a.cmd == "checkpaths":
        sys.exit(1 if checkpaths(a.files) else 0)
    elif a.cmd == "unwith":
        names = set(json.loads(subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr",
             "builtins.attrNames (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib"],
            check=True, capture_output=True, text=True).stdout))
        failed = False
        for path in a.files:
            try:
                print(f"unwith    {path}: {unwith(path, names)} names prefixed")
            except Exception as e:  # noqa: BLE001
                print(f"SKIPPED   {path}: {e}", file=sys.stderr)
                failed = True
        sys.exit(1 if failed else 0)
    elif a.cmd == "fixpaths":
        fixpaths(a.old_root, a.new_root)
    else:
        failed = False
        for path in a.files:
            try:
                new = wrap(open(path).read(), a.into, a.key, os.path.dirname(os.path.abspath(path)), os.path.abspath(a.root))
                if new is None:
                    subprocess.run(["git", "rm", "-qf", path], check=True)
                    print(f"DELETED {path}: it only imported its siblings")
                else:
                    open(path, "w").write(new)
            except Exception as e:  # noqa: BLE001 - report every file, then fail
                print(f"SKIPPED {path}: {e}", file=sys.stderr)
                failed = True
        sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
