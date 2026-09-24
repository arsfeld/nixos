# media.services Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every direct `media.gateway.services` write onto `media.services`, then make a direct write to `media.gateway.services` or `media.containers` fail evaluation.

**Architecture:** Seven gateway-only entries are rewritten as `media.services.<name>` declarations. `media.services` lowers them to identical values, so every host's `drvPath` stays unchanged. An assertion in `modules/media/services.nix` then reads `options.<path>.files` and rejects any defining file outside an allowlist. A flake check proves the assertion fires, by adding a probe module to galactica and inspecting `config.assertions`.

**Tech Stack:** NixOS module system (`options.<path>.files`, `assertions`, `extendModules`), flake-parts checks.

Spec: `docs/superpowers/specs/2026-09-24-media-services-enforcement-design.md`

## Global Constraints

- No host may change semantically. Because the flake source is in every closure, compare with `nix-diff` at the same HEAD: the only allowed differences are the source path and its revision. Anything else is a bug; do not accept it. (Corrected during execution; the original wording asked for identical `drvPath`s, which cannot hold.)
- Scope is `media.gateway.services` and `media.containers` only. Do not touch `virtualisation.oci-containers.containers` writers (planka, siyuan, iroh-relay, isponsorblock, vpn-exit-nodes, tsnsrv).
- `hosts/galactica/services/files.nix` has an unrelated uncommitted change. Never stage or commit it, and never revert it. Commit with explicit paths (`git commit -- <paths>`). The change is part of the working tree that every eval sees, so leave it alone throughout, and both the baseline and the after-hashes will include it consistently.
- Conventional commits, no mention of Claude, and no attribution lines. Commit straight to master (no branches).
- Run nix commands from the repo root, `/home/arosenfeld/Code/nixos`. Flakes only see tracked files, and this plan creates none that nix must evaluate.

---

### Task 1: Record baseline drvPaths

**Files:**
- Create: `$SCRATCH/hashes.sh`, where `$SCRATCH` is the session scratchpad directory (not in the repo)
- Output: `$SCRATCH/before.txt`

**Interfaces:**
- Produces: `$SCRATCH/hashes.sh <outfile>` writes one `<host> <drvPath>` line per host, sorted. Tasks 2 and 3 compare against `before.txt`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Usage: hashes.sh <outfile> — one "<host> <toplevel drvPath>" line per host.
set -euo pipefail
cd /home/arosenfeld/Code/nixos
out=$1
: > "$out"
for h in $(nix eval --json --apply builtins.attrNames .#nixosConfigurations 2>/dev/null | tr -d '[]"' | tr ',' ' '); do
  p=$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" 2>/dev/null) || p="EVAL-FAILED"
  echo "$h $p" >> "$out"
done
sort -o "$out" "$out"
cat "$out"
```

- [ ] **Step 2: Run it before any change**

Run: `bash $SCRATCH/hashes.sh $SCRATCH/before.txt`

Expected: 10 lines (basestar, blackbird, cylon-link, galactica, octopi, pegasus, r2s, raider, raspi3, router), each ending in `.drv`, with no `EVAL-FAILED`. If any host fails to evaluate on the untouched tree, stop and report it: it would make the comparison meaningless for that host.

No commit.

---

### Task 2: Migrate the seven gateway entries onto media.services

**Files:**
- Modify: `hosts/galactica/services/beszel.nix:14-17`
- Modify: `hosts/galactica/services/ntfy.nix:4-7`
- Modify: `hosts/galactica/services/infra.nix:6-16`
- Modify: `hosts/galactica/services/home-assistant.nix:27-33`
- Modify: `hosts/galactica/services/opencloud.nix:75-81`
- Modify: `modules/blocky.nix:42-45`

**Interfaces:**
- Consumes: `media.services.<name>` with fields `port`, `bypassAuth`, `tailscaleExposed` (defined in `modules/media/services.nix`). For `container = null` it lowers to `media.gateway.services.<name> = {port; exposeViaTailscale = true (only if tailscaleExposed); settings = mkDefault {bypassAuth; cors; funnel; insecureTls;};}`.
- Produces: no file outside `modules/media/` defines `media.gateway.services`. Task 3's guard depends on this.

The "test" here is hash equality: a mistranslation (wrong port, a dropped `exposeViaTailscale`) changes galactica's `drvPath`.

- [ ] **Step 1: beszel.nix.** Replace

```nix
  media.gateway.services.beszel = {
    port = hubPort;
    settings.bypassAuth = true;
  };
```

with

```nix
  media.services.beszel = {
    port = hubPort;
    bypassAuth = true;
  };
```

- [ ] **Step 2: ntfy.nix.** Replace

```nix
  media.gateway.services.ntfy = {
    port = 2586;
    settings.bypassAuth = true;
  };
```

with

```nix
  media.services.ntfy = {
    port = 2586;
    bypassAuth = true;
  };
```

- [ ] **Step 3: infra.nix.** Replace

```nix
  media.gateway.services.netdata = {
    port = 19999;
    exposeViaTailscale = true;
  };
  media.gateway.services.grafana = {
    port = 3010;
    exposeViaTailscale = true;
    settings = {
      bypassAuth = true;
    };
  };
```

with

```nix
  media.services.netdata = {
    port = 19999;
    tailscaleExposed = true;
  };
  media.services.grafana = {
    port = 3010;
    tailscaleExposed = true;
    bypassAuth = true;
  };
```

- [ ] **Step 4: home-assistant.nix.** Replace

```nix
    media.gateway.services.hass = {
      port = 8123;
      exposeViaTailscale = true;
      settings = {
        bypassAuth = true;
      };
    };
```

with

```nix
    media.services.hass = {
      port = 8123;
      tailscaleExposed = true;
      bypassAuth = true;
    };
```

- [ ] **Step 5: opencloud.nix.** Replace

```nix
    media.gateway.services.opencloud = {
      port = 9200;
      exposeViaTailscale = true;
      settings = {
        bypassAuth = true;
      };
    };
```

with

```nix
    media.services.opencloud = {
      port = 9200;
      tailscaleExposed = true;
      bypassAuth = true;
    };
```

- [ ] **Step 6: blocky.nix.** Replace

```nix
    media.gateway.services.dns = {
      port = dnsPort;
      settings.bypassAuth = true;
    };
```

with

```nix
    media.services.dns = {
      port = dnsPort;
      bypassAuth = true;
    };
```

Blocky is enabled on no host, so hash equality cannot cover this change. Step 8 checks it directly.

- [ ] **Step 7: Confirm no direct writers remain**

Run: `grep -rn 'media\.gateway\.services\.[a-z]* *=' --include=*.nix hosts modules | grep -v '^modules/media/'`
Expected: no output.

- [ ] **Step 8: Check the blocky translation by evaluation**

Run:

```bash
nix eval --json --impure --expr '
let f = builtins.getFlake (toString ./.);
    g = f.nixosConfigurations.galactica.extendModules { modules = [ { blocky.enable = true; } ]; };
    s = g.config.media.gateway.services.dns;
in { inherit (s) port exposeViaTailscale; inherit (s.settings) bypassAuth; }'
```

Expected: `{"bypassAuth":true,"exposeViaTailscale":false,"port":<nameToPort "dns">}`, where the port is a number equal to `nix eval --impure --expr '(import ./common/nameToPort.nix) "dns"'`.

- [ ] **Step 9: Compare hashes**

Run: `bash $SCRATCH/hashes.sh $SCRATCH/after-migrate.txt && diff $SCRATCH/before.txt $SCRATCH/after-migrate.txt && echo IDENTICAL`
Expected: `IDENTICAL`. If galactica differs, diff the two derivations (`nix-diff` is not guaranteed to be installed; use `nix derivation show <drv> | jq` on each and compare the caddy config and tsnsrv units) and fix the translation. Do not proceed on a mismatch.

- [ ] **Step 10: Commit**

```bash
git commit -m "refactor(galactica): declare gateway-only services through media.services" -- \
  hosts/galactica/services/beszel.nix hosts/galactica/services/ntfy.nix \
  hosts/galactica/services/infra.nix hosts/galactica/services/home-assistant.nix \
  hosts/galactica/services/opencloud.nix modules/blocky.nix
```

---

### Task 3: Guard the lower layers, with a flake check proving it

**Files:**
- Modify: `flake-modules/checks.nix` (add `media-lower-layers-guarded` to the `x86_64-linux`-only block)
- Modify: `modules/media/services.nix` (header comment, module args, `let` helper, `config.assertions`)

**Interfaces:**
- Consumes: Task 2's state, in which no host file writes `media.gateway.services`.
- Produces: assertions whose `message` starts with the option path (`media.gateway.services` or `media.containers`) and lists each offending file relative to the repo root (store prefix stripped), or the raw `_file` string for modules that are not files. The flake check matches on both.

- [ ] **Step 1: Write the failing check.** In `flake-modules/checks.nix`, add to the `// inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") { ... }` block, after `cylon-link-config`:

```nix
        # The media lower layers (media.gateway.services, media.containers)
        # may only be written by modules/media/; services.nix asserts it.
        # Probe galactica with a stray write to each and require that the
        # assertion fires and names the probe. Reads config.assertions rather
        # than tryEval'ing the toplevel, so an unrelated eval error cannot
        # pass for the guard working.
        media-lower-layers-guarded = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          probed = self.nixosConfigurations.galactica.extendModules {
            modules = [
              {
                _file = "media-guard-probe";
                media.gateway.services.probe.port = 1;
                media.containers.probe = {};
              }
            ];
          };
          fires = path:
            lib.any (a: !a.assertion && lib.hasPrefix path a.message && lib.hasInfix "media-guard-probe" a.message)
            probed.config.assertions;
          missing = lib.filter (p: !fires p) ["media.gateway.services" "media.containers"];
        in
          if missing == []
          then pkgs.runCommand "media-lower-layers-guarded" {} "touch $out"
          else throw "media lower-layer guard did not fire for: ${lib.concatStringsSep ", " missing}";
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nix build --no-link .#checks.x86_64-linux.media-lower-layers-guarded`
Expected: an eval error containing `media lower-layer guard did not fire for: media.gateway.services, media.containers`. This run is the spec's "confirm the check fails without the guard".

- [ ] **Step 3: Add the guard.** In `modules/media/services.nix`:

(a) Update the header comment. Replace

```nix
# Each entry is *lowered* into the existing media.containers.<name> /
# media.gateway.services.<name> options (unchanged underneath). Those two
# options remain implementation/lowering targets and should not be written by
# hand.
```

with

```nix
# Each entry is *lowered* into the existing media.containers.<name> /
# media.gateway.services.<name> options (unchanged underneath). Those two
# options are lowering targets only: the assertions at the bottom of this file
# reject a definition of either from any file outside modules/media/.
```

(b) Add `options` to the module arguments:

```nix
{
  self,
  config,
  options,
  lib,
  ...
}:
```

(c) In the `let` block, directly after `podmanSubnet = "10.88.0.0/16";`, add:

```nix

  # Reject definitions of a lower-layer option from any file not in `allowed`
  # (paths relative to the repo root). `opt.files` lists each file whose
  # definition survived mkIf, as a store path, so match by suffix and strip the
  # store prefix for the message.
  guardLowerLayer = path: opt: allowed: let
    strays = unique (filter (f: !any (a: hasSuffix "/${a}" f) allowed) opt.files);
  in {
    assertion = strays == [];
    message = ''
      ${path} is written only by media.services; declare media.services.<name> instead.
      Defined directly in: ${concatMapStringsSep ", " (f: last (splitString "-source/" f)) strays}
    '';
  };
```

(d) In the `config = { ... };` attrset at the bottom, after the `systemd.services = ...;` line, add:

```nix
    assertions = [
      (guardLowerLayer "media.gateway.services" options.media.gateway.services
        ["modules/media/services.nix" "modules/media/containers.nix"])
      (guardLowerLayer "media.containers" options.media.containers
        ["modules/media/services.nix"])
    ];
```

`assertions` is a static key like the other three, so it adds no recursion. The existing comment above `config` explains why the keys must stay static.

- [ ] **Step 4: Run the check to verify it passes**

Run: `nix build --no-link .#checks.x86_64-linux.media-lower-layers-guarded`
Expected: success, with no output.

- [ ] **Step 5: See the message a real offender gets**

Run:

```bash
nix eval --impure --expr '
let f = builtins.getFlake (toString ./.);
    g = f.nixosConfigurations.galactica.extendModules { modules = [ { _file = "media-guard-probe"; media.gateway.services.probe.port = 1; } ]; };
in g.config.system.build.toplevel.drvPath' 2>&1 | grep -A2 'Failed assertions'
```

Expected: `Failed assertions:` followed by `- media.gateway.services is written only by media.services; declare media.services.<name> instead.` and `Defined directly in: media-guard-probe`.

- [ ] **Step 6: Compare hashes on every host**

Raw `drvPath` equality cannot hold: the flake source (`self`) is in every closure, so any tracked change shifts every host's path. Other sessions may also be committing to master. So: stash your edits, run `bash $SCRATCH/hashes.sh $SCRATCH/pre-guard.txt` at the current HEAD, pop the stash, run `bash $SCRATCH/hashes.sh $SCRATCH/after-guard.txt`, and for every host whose paths differ run `nix run nixpkgs#nix-diff -- <pre.drv> <after.drv>`.
Expected: no `EVAL-FAILED`, and every nix-diff difference traces only to the flake source path and its revision (`nix.registry.self.flake`, `NIX_PATH`, the sops `sopsFile` prefix, basestar's blog source). A difference in any package, unit or `/etc` file is a failure. The script evaluates each toplevel, which forces assertions, so this also proves the guard passes on every real host. `EVAL-FAILED` on any host means the guard is over-strict there. Inspect that host with `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` (without `2>/dev/null`) to see the assertion message.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(modules): reject direct writes to media.gateway.services and media.containers" -- \
  modules/media/services.nix flake-modules/checks.nix
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md` (the paragraph under "#### `media.services.<name>` is the only way to declare a service")
- Modify: `docs/superpowers/specs/2026-09-24-media-services-enforcement-design.md` (Verification step 2)

- [ ] **Step 1: CLAUDE.md.** Replace this sentence:

```
Do **not** write to `virtualisation.oci-containers.containers`, `media.gateway.services`, or `media.containers` by hand — those are implementation details and bypassing `media.services` will silently miss the standardized PUID/PGID/TZ env, the auto-tmpfiles config dir, the gateway entry, and image-watching.
```

with:

```
`media.gateway.services` and `media.containers` are lowering targets, and writing either by hand fails evaluation: an assertion in `modules/media/services.nix` rejects a definition from any file outside `modules/media/` and names the file. `checks.x86_64-linux.media-lower-layers-guarded` proves the assertion still fires. Reading them (glance, auth, pegasus, `podman.nix`) is fine. `virtualisation.oci-containers.containers` is **not** guarded. Writing it directly still bypasses the standardized PUID/PGID/TZ env, the auto-tmpfiles config dir, the gateway entry and image-watching, so don't do it for a new service. Five modules still do, as known exceptions that `media.services` cannot express without changing their units: basestar's `planka`, `siyuan` and `iroh-relay` (own `*.arsfeld.dev` vhosts; iroh-relay needs host networking) and galactica's `isponsorblock` and `vpn-exit-nodes` (both disabled). `modules/tsnsrv.nix` writes it for its sidecars, which is legitimate.
```

- [ ] **Step 2: Spec.** In the spec's "## Verification" section, replace item 2 (starting `2. **Negative check.**`) with:

```
2. **Negative check.** Add `checks.x86_64-linux.media-lower-layers-guarded` to
   `flake-modules/checks.nix`. It extends galactica with a probe module
   (`_file = "media-guard-probe"`) writing both `media.gateway.services.probe`
   and `media.containers.probe`, and requires that `config.assertions` holds a
   failing assertion for each option naming the probe. It reads the assertions
   rather than `tryEval`ing the toplevel, so an unrelated eval error cannot pass
   for the guard working. It runs in `checks.yml`.
```

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: record that media lower layers are enforced, not conventional" -- \
  CLAUDE.md docs/superpowers/specs/2026-09-24-media-services-enforcement-design.md
```

- [ ] **Step 4: Final state**

Run: `git status --short && git log --oneline -4`
Expected: only ` M hosts/galactica/services/files.nix` remains modified, and the last three commits are Tasks 2–4.
