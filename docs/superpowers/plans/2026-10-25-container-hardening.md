# Container Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every `media.services` container with `--cap-drop=ALL`, a per-image capability add-back list and `no-new-privileges`, rolled out pegasus → basestar → galactica without breaking a service.

**Architecture:** A `hardening` submodule on `media.containers.<name>` (`modules/media/containers.nix`) adds the podman flags in the existing `oci-containers` lowering. `media.services.<name>.container` is a free-form attrset merged into `media.containers.<name>`, so services set `container.hardening.*` with no change to `services.nix`. A flake check pins the generated flags. Rollout uses throwaway scripts in `/tmp/hardening/` that run each image twice (control and hardened) before each host's deploy and verify the result afterwards.

**Tech Stack:** NixOS modules, flake-parts checks, podman, POSIX sh, `jq` via `nix run nixpkgs#jq`.

Spec: `docs/superpowers/specs/2026-10-25-container-hardening-design.md`.

## Global Constraints

- Default `caps` for images starting `ghcr.io/linuxserver/` or `lscr.io/linuxserver/`: `CHOWN DAC_OVERRIDE FOWNER SETUID SETGID KILL`. Every other image: `[]`.
- Flags, in this order: `--cap-drop=ALL`, one `--cap-add=<CAP>` per entry, `--security-opt=no-new-privileges`. Cap names have no `CAP_` prefix.
- `privileged = true` containers get no hardening flags.
- Every explicit `caps` value and every `hardening.enable = false` carries a comment saying why.
- Commit straight to master; never branch or use a worktree. Conventional commits: `<type>(<scope>): <subject>`. Never mention Claude.
- **Do not push until the galactica wave (Task 5) passes.** The weekly update routine deploys `origin/master` to tier 1 on Saturday 03:00 America/Toronto; a pushed default-on change would reach galactica unprobed. Deploys from raider use the local tree and are unaffected.
- Do not re-enable hermes, ask, radarr, sonarr or jackett (disabled in `1fcac3d8` for CVE-2026-111497).
- Out of scope, leave untouched: planka, siyuan, iroh-relay, isponsorblock, vpn-exit-nodes, tsnsrv sidecars, k3s pods.
- Run `nix` commands from `/home/arosenfeld/Code/nixos` on raider, inside `nix develop` for `just`.
- Don't read files or logs with `cat`/`head`/`tail`; use the Read tool or `grep`.

---

### Task 1: `hardening` option, lowering, check and docs

**Files:**
- Modify: `modules/media/containers.nix` (let block near line 28; options after `watchImageInterval` near line 205; `extraOptions` in the lowering near line 416)
- Modify: `flake-modules/checks.nix` (inside the `x86_64-linux` attrset, after `media-lower-layers-guarded`)
- Modify: `CLAUDE.md` (the `media.services` example block under "`media.services.<name>` is the only way to declare a service")
- Modify: `docs/superpowers/specs/2026-10-25-container-hardening-design.md` (per-wave check 4)

**Interfaces:**
- Produces: `media.containers.<name>.hardening.enable : bool` (default `true`) and `media.containers.<name>.hardening.caps : listOf str` (default by image). Set from services as `media.services.<name>.container.hardening.{enable,caps}`.
- Produces: flake check `checks.x86_64-linux.media-container-hardening`.

- [ ] **Step 1: Write the failing check**

In `flake-modules/checks.nix`, add after the closing of `media-lower-layers-guarded` (still inside the `optionalAttrs (system == "x86_64-linux")` attrset):

```nix
        # Every media container is hardened by default (see
        # docs/superpowers/specs/2026-10-25-container-hardening-design.md).
        # Probe galactica with one service per case and compare the
        # generated capability and security flags exactly.
        media-container-hardening = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          other = "docker.io/example/other:latest";
          probed = self.nixosConfigurations.galactica.extendModules {
            modules = [
              {
                media.services = {
                  hprobe-lsio = {
                    port = 1;
                    container = {};
                  };
                  hprobe-other = {
                    port = 2;
                    image = other;
                    container = {};
                  };
                  hprobe-caps = {
                    port = 3;
                    image = other;
                    container.hardening.caps = ["NET_ADMIN"];
                  };
                  hprobe-optout = {
                    port = 4;
                    container.hardening.enable = false;
                  };
                  hprobe-priv = {
                    port = 5;
                    container.privileged = true;
                  };
                };
              }
            ];
          };
          flags = n:
            lib.filter (o: lib.hasPrefix "--cap-" o || lib.hasPrefix "--security-opt" o)
            probed.config.virtualisation.oci-containers.containers.${n}.extraOptions;
          wrap = caps: ["--cap-drop=ALL"] ++ map (c: "--cap-add=${c}") caps ++ ["--security-opt=no-new-privileges"];
          expect = {
            hprobe-lsio = wrap ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "KILL"];
            hprobe-other = wrap [];
            hprobe-caps = wrap ["NET_ADMIN"];
            hprobe-optout = [];
            hprobe-priv = [];
          };
          wrong = lib.filter (n: flags n != expect.${n}) (lib.attrNames expect);
        in
          if wrong == []
          then pkgs.runCommand "media-container-hardening" {} "touch $out"
          else throw "hardening flags wrong for: ${lib.concatMapStringsSep "; " (n: "${n} = ${builtins.toJSON (flags n)}") wrong}";
```

- [ ] **Step 2: Run it and verify it fails**

Run: `nix build .#checks.x86_64-linux.media-container-hardening --no-link 2>&1 | grep -E "error|hardening"`
Expected: FAIL, an evaluation error that the option `hardening` does not exist (or the `throw` listing all three hardened probes with `[]`).

- [ ] **Step 3: Add the option and the lowering**

In `modules/media/containers.nix`, add to the `let` block after `backendBin`:

```nix
  # linuxserver images start as root under s6 and drop to PUID/PGID, which
  # needs these. Every other image starts with none and is given what it
  # needs explicitly.
  linuxserverCaps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "KILL"];
  isLinuxserver = image:
    hasPrefix "ghcr.io/linuxserver/" image || hasPrefix "lscr.io/linuxserver/" image;
```

Add after the `watchImageInterval` option:

```nix
        hardening = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Run with --cap-drop=ALL, the capabilities in `caps`, and
              no-new-privileges. Ignored for privileged containers. Opt out
              only with a comment saying why; see
              docs/superpowers/specs/2026-10-25-container-hardening-design.md.
            '';
          };
          caps = mkOption {
            type = types.listOf types.str;
            default =
              if isLinuxserver config.image
              then linuxserverCaps
              else [];
            defaultText = literalExpression ''
              if the image is ghcr.io/linuxserver/* or lscr.io/linuxserver/*
              then ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "KILL"]
              else []
            '';
            description = ''
              Capabilities, without the CAP_ prefix, added back after
              --cap-drop=ALL. Comment any explicit value with the reason.
            '';
          };
        };
```

In the lowering, change `extraOptions` to:

```nix
              extraOptions = flatten [
                (optional (container.network != null) "--network=${container.network}")
                (optional container.privileged "--privileged")
                (optionals (container.hardening.enable && !container.privileged) (
                  ["--cap-drop=ALL"]
                  ++ map (cap: "--cap-add=${cap}") container.hardening.caps
                  ++ ["--security-opt=no-new-privileges"]
                ))
                (map (device: "--device=${device}") container.devices)
                container.extraOptions
              ];
```

- [ ] **Step 4: Run the check and verify it passes**

Run: `nix build .#checks.x86_64-linux.media-container-hardening --no-link && echo PASS`
Expected: `PASS`.

Also run: `nix build .#checks.x86_64-linux.media-lower-layers-guarded --no-link && echo PASS`
Expected: `PASS` (the guard still fires).

- [ ] **Step 5: Document it**

In `CLAUDE.md`, inside the `media.services` example's `container = { ... };` block, after the `extraOptions` line, add:

```nix
      hardening.caps = ["NET_ADMIN"]; # added back after --cap-drop=ALL; default: s6 set for linuxserver images, none otherwise
      # hardening.enable = false;    # opt out, with a comment saying why
```

After the paragraph starting "Set `database.postgres = true`", add:

```markdown
Every container runs with `--cap-drop=ALL`, `--security-opt=no-new-privileges` and only the capabilities in `container.hardening.caps`: linuxserver images default to `CHOWN DAC_OVERRIDE FOWNER SETUID SETGID KILL` (s6 starts as root and drops to PUID/PGID), everything else to none. A new image that fails to start with `Operation not permitted` needs its caps listed. Privileged containers are skipped. Design: `docs/superpowers/specs/2026-10-25-container-hardening-design.md`.
```

In the spec, replace per-wave check 4 with:

```markdown
4. Every hardened container's published port on `127.0.0.1` answers with
   something other than a 5xx or a connection failure. This tests the
   container itself rather than the gateway in front of it.
```

- [ ] **Step 6: Format, confirm hosts still evaluate, commit**

Run: `nix develop -c just fmt`
Run: `for h in galactica basestar pegasus; do nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath >/dev/null && echo "$h ok"; done`
Expected: three `ok` lines.

```bash
git add modules/media/containers.nix flake-modules/checks.nix CLAUDE.md docs/superpowers/specs/2026-10-25-container-hardening-design.md
git commit -m "feat(modules): drop container capabilities by default"
```

Do not push (Global Constraints).

---

### Task 2: Rollout tooling (throwaway, not committed)

**Files:**
- Create: `/tmp/hardening/probe-list.sh`, `/tmp/hardening/probe.sh`, `/tmp/hardening/post-list.sh`, `/tmp/hardening/post-check.sh`

**Interfaces:**
- Consumes: Task 1's flags in `config.virtualisation.oci-containers.containers.<n>.extraOptions`.
- Produces: `probe-list.sh <host>` → TSV `name image flags devices cmd`; `probe.sh`, run on the host as root with `LIST=<tsv path>` (see Step 5) → lines `name VERDICT detail`, VERDICT ∈ `PASS FAIL INCONCLUSIVE`; `post-list.sh <host>` → TSV `name caps port`; `post-check.sh`, run the same way with `LIST=<tsv path>` → lines `name OK|problems http=<code>`.

- [ ] **Step 1: Write `/tmp/hardening/probe-list.sh`**

```bash
#!/usr/bin/env bash
# usage: probe-list.sh <host> -> TSV: name image hardened-flags devices cmd
# Only containers carrying --cap-drop=ALL (i.e. hardened ones) are listed.
set -euo pipefail
cd /home/arosenfeld/Code/nixos
nix eval --json ".#nixosConfigurations.$1.config.virtualisation.oci-containers.containers" --apply '
  cs: builtins.mapAttrs (n: c: {
    image = c.image;
    cmd = c.cmd;
    flags = builtins.filter (o: builtins.match "--(cap-drop|cap-add|security-opt).*" o != null) c.extraOptions;
    devices = builtins.filter (o: builtins.match "--device.*" o != null) c.extraOptions;
  }) cs' 2>/dev/null |
  nix run nixpkgs#jq -- -r 'to_entries[]
    | select(.value.flags | index("--cap-drop=ALL"))
    | [.key, .value.image, (.value.flags|join(" ")), (.value.devices|join(" ")), (.value.cmd|map(@sh)|join(" "))]
    | @tsv'
```

- [ ] **Step 2: Write `/tmp/hardening/probe.sh`**

Runs on the target host as root. Reads the TSV from a file named by `$LIST`.

```sh
#!/bin/sh
# Runs each listed image twice with no volumes, ports or env files: a control
# (podman defaults) and a hardened copy. Only "control up, hardened down or
# new permission errors" is a hardening failure.
WAIT=${WAIT:-45}
BATCH=${BATCH:-6}
pat='Operation not permitted|EPERM|[Pp]ermission denied'
start() { # name image flags devices cmd
  eval "podman run -d --name capprobe-c-$1 $4 $2 $5" >/dev/null 2>&1
  eval "podman run -d --name capprobe-h-$1 $3 $4 $2 $5" >/dev/null 2>&1
}
errs() { podman logs "$1" 2>&1 | grep -E "$pat" | sed 's/[0-9]//g' | sort -u; }
classify() {
  n=$1
  c=$(podman inspect -f '{{.State.Running}}' "capprobe-c-$n" 2>/dev/null || echo false)
  h=$(podman inspect -f '{{.State.Running}}' "capprobe-h-$n" 2>/dev/null || echo false)
  errs "capprobe-c-$n" > "/tmp/cp-c-$n"
  errs "capprobe-h-$n" > "/tmp/cp-h-$n"
  new=$(comm -13 "/tmp/cp-c-$n" "/tmp/cp-h-$n" | sed -n 1,3p | tr '\n' ' ')
  if [ "$c" != true ]; then v=INCONCLUSIVE
  elif [ "$h" != true ] || [ -n "$new" ]; then v=FAIL
  else v=PASS; fi
  printf '%s\t%s\tcontrol=%s hardened=%s\t%s\n' "$n" "$v" "$c" "$h" "$new"
  podman rm -f "capprobe-c-$n" "capprobe-h-$n" >/dev/null 2>&1
  rm -f "/tmp/cp-c-$n" "/tmp/cp-h-$n"
}
podman ps -a --format '{{.Names}}' | grep '^capprobe-' | xargs -r podman rm -f >/dev/null 2>&1
names=""; i=0
while IFS='	' read -r n img flags devs cmd; do
  start "$n" "$img" "$flags" "$devs" "$cmd"; names="$names $n"; i=$((i+1))
  if [ "$i" -ge "$BATCH" ]; then sleep "$WAIT"; for x in $names; do classify "$x"; done; names=""; i=0; fi
done < "$LIST"
if [ -n "$names" ]; then sleep "$WAIT"; for x in $names; do classify "$x"; done; fi
```

- [ ] **Step 3: Write `/tmp/hardening/post-list.sh`**

```bash
#!/usr/bin/env bash
# usage: post-list.sh <host> -> TSV: name expected-caps(comma) published-host-port
set -euo pipefail
cd /home/arosenfeld/Code/nixos
nix eval --json ".#nixosConfigurations.$1.config.virtualisation.oci-containers.containers" --apply '
  cs: builtins.mapAttrs (n: c: {
    hardened = builtins.elem "--cap-drop=ALL" c.extraOptions;
    caps = map (o: builtins.substring 10 100 o)
      (builtins.filter (o: builtins.match "--cap-add=.*" o != null) c.extraOptions);
    port = if c.ports == [] then "" else builtins.head (builtins.split ":" (builtins.head c.ports));
  }) cs' 2>/dev/null |
  nix run nixpkgs#jq -- -r 'to_entries[] | select(.value.hardened) | [.key, (.value.caps|join(",")), .value.port] | @tsv'
```

- [ ] **Step 4: Write `/tmp/hardening/post-check.sh`**

Runs on the host as root, reading the TSV from `$LIST`.

```sh
#!/bin/sh
while IFS='	' read -r n caps port; do
  eff=$(podman inspect -f '{{range .EffectiveCaps}}{{.}} {{end}}' "$n" 2>/dev/null) || { printf '%s\tNOT RUNNING\n' "$n"; continue; }
  eff=$(echo $eff | tr ' ' '\n' | sed 's/^CAP_//; /^$/d' | sort | tr '\n' ',')
  want=$(echo "$caps" | tr ',' '\n' | sed '/^$/d' | sort | tr '\n' ',')
  ok=OK
  [ "$eff" = "$want" ] || ok="CAPS(have=$eff want=$want)"
  podman inspect -f '{{.HostConfig.SecurityOpt}}' "$n" | grep -q no-new-privileges || ok="$ok NNP-MISSING"
  code=-
  if [ -n "$port" ]; then
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$port/")
    case $code in 5*|000) ok="$ok HTTP=$code";; esac
  fi
  printf '%s\t%s\thttp=%s\n' "$n" "$ok" "$code"
done < "$LIST"
```

If `curl` is missing on a host, replace `curl` with `nix run nixpkgs#curl --`.

- [ ] **Step 5: Smoke-test the probe on pegasus**

Run:
```bash
chmod +x /tmp/hardening/*.sh
/tmp/hardening/probe-list.sh pegasus > /tmp/hardening/pegasus.tsv
grep -c . /tmp/hardening/pegasus.tsv
scp /tmp/hardening/pegasus.tsv /tmp/hardening/probe.sh root@pegasus.bat-boa.ts.net:/tmp/
ssh root@pegasus.bat-boa.ts.net 'LIST=/tmp/pegasus.tsv sh /tmp/probe.sh'
```
Expected: the TSV has 7 lines (flaresolverr, mydia, plex, prowlarr, stash, transmission, yarr; adjust if pegasus's container set changed), and the probe prints one verdict line per container. Afterwards `ssh root@pegasus.bat-boa.ts.net "podman ps -a | grep -c capprobe"` prints `0`.

Nothing to commit.

---

### Task 3: pegasus wave

**Files:**
- Modify: `hosts/pegasus/services/transmission.nix:71-74`
- Modify: whichever `hosts/pegasus/services/*.nix` file declares a container the probe marks FAIL

**Interfaces:**
- Consumes: Task 2 scripts.

- [ ] **Step 1: Move transmission's NET_ADMIN into `caps`**

In `hosts/pegasus/services/transmission.nix`, replace

```nix
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun"
      ];
```

with

```nix
      # OpenVPN configures the tunnel and its kill-switch firewall itself.
      hardening.caps = ["NET_ADMIN"];
      extraOptions = [
        "--device=/dev/net/tun"
      ];
```

- [ ] **Step 2: Probe**

Run Task 2 Step 5's commands again, regenerating the TSV first.

- [ ] **Step 3: Fix every FAIL**

For each FAIL, read the new error lines in the verdict and add the missing capabilities to that service's `container.hardening.caps`, with a comment naming what needs them. Start from the image's default (`[]`, or the linuxserver set) and add only what the errors point to. The usual mapping:
- `chown … Operation not permitted` → `CHOWN`
- `setgroups`/`setgid`/`setuid`/`su-exec`/`gosu` failures → `SETUID`, `SETGID`
- root failing to read or write a file owned by another user → `DAC_OVERRIDE`, `FOWNER`
- binding a port below 1024 → `NET_BIND_SERVICE`
- `iptables`/`ip route`/`tun` → `NET_ADMIN`

Regenerate the TSV and re-probe until no FAIL remains. Opt out (`hardening.enable = false` with a comment) only if the caps list grows past podman's default set.

Note INCONCLUSIVE containers by name; Step 6 covers them.

- [ ] **Step 4: Snapshot and build**

```bash
ssh root@pegasus.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" > /tmp/hardening/pegasus-before
nix develop -c just build pegasus
```
Expected: the build succeeds.

- [ ] **Step 5: Deploy**

Run: `nix develop -c just deploy pegasus`
Expected: ends with `Done.`; the activation log restarts every `podman-*` unit it hardened.

- [ ] **Step 6: Verify**

Wait 60 seconds for the s6 images to finish starting, then:
```bash
/tmp/hardening/post-list.sh pegasus > /tmp/hardening/pegasus-post.tsv
scp /tmp/hardening/pegasus-post.tsv /tmp/hardening/post-check.sh root@pegasus.bat-boa.ts.net:/tmp/
ssh root@pegasus.bat-boa.ts.net 'LIST=/tmp/pegasus-post.tsv sh /tmp/post-check.sh; systemctl --failed --no-legend'
ssh root@pegasus.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" | diff /tmp/hardening/pegasus-before - && echo "same containers"
```
Expected: every line `OK`, no failed units, `same containers`.

For any failure: `ssh root@pegasus.bat-boa.ts.net journalctl -u podman-<name> -n 50 --no-pager`, add caps as in Step 3, redeploy, repeat this step.

- [ ] **Step 7: Commit**

```bash
git add hosts/pegasus
git commit -m "feat(pegasus): run containers with dropped capabilities"
```

---

### Task 4: basestar wave

**Files:**
- Modify: whichever `hosts/basestar/services/*.nix` file declares a container the probe marks FAIL

**Interfaces:**
- Consumes: Task 2 scripts.

basestar is aarch64, and it is also the niks3 write endpoint in CI's push path.

- [ ] **Step 1: Probe**

```bash
/tmp/hardening/probe-list.sh basestar > /tmp/hardening/basestar.tsv
grep -c . /tmp/hardening/basestar.tsv
scp /tmp/hardening/basestar.tsv /tmp/hardening/probe.sh root@basestar.bat-boa.ts.net:/tmp/
ssh root@basestar.bat-boa.ts.net 'LIST=/tmp/basestar.tsv sh /tmp/probe.sh'
```
Expected: one verdict per hardened container (chat, webui, plus any other `media.services` containers; planka, siyuan and iroh-relay must **not** appear).

- [ ] **Step 2: Fix every FAIL**

Follow Task 3 Step 3's procedure and mapping, editing the file under `hosts/basestar/services/` that declares the container. Re-probe until no FAIL remains.

- [ ] **Step 3: Snapshot and build**

```bash
ssh root@basestar.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" > /tmp/hardening/basestar-before
nix develop -c just build basestar
```

- [ ] **Step 4: Deploy outside a CI push**

Run: `gh run list --workflow build.yml --status in_progress --limit 5`
Expected: no runs. If one is running, wait for it to finish (deploying basestar mid-run fails that run's niks3 push).

Run: `nix develop -c just deploy basestar`
Expected: ends with `Done.`.

- [ ] **Step 5: Verify**

Wait 60 seconds, then:
```bash
/tmp/hardening/post-list.sh basestar > /tmp/hardening/basestar-post.tsv
scp /tmp/hardening/basestar-post.tsv /tmp/hardening/post-check.sh root@basestar.bat-boa.ts.net:/tmp/
ssh root@basestar.bat-boa.ts.net 'LIST=/tmp/basestar-post.tsv sh /tmp/post-check.sh; systemctl --failed --no-legend'
ssh root@basestar.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" | diff /tmp/hardening/basestar-before - && echo "same containers"
```
Expected: every line `OK`, no failed units, `same containers`. Fix failures as in Task 3 Step 6.

- [ ] **Step 6: Commit**

```bash
git add hosts/basestar
git commit -m "feat(basestar): run containers with dropped capabilities"
```
(If no file changed, skip the commit.)

---

### Task 5: galactica wave, then push

**Files:**
- Modify: whichever `hosts/galactica/services/*.nix` file declares a container the probe marks FAIL

**Interfaces:**
- Consumes: Task 2 scripts.

- [ ] **Step 1: Probe**

```bash
/tmp/hardening/probe-list.sh galactica > /tmp/hardening/galactica.tsv
grep -c . /tmp/hardening/galactica.tsv
scp /tmp/hardening/galactica.tsv /tmp/hardening/probe.sh root@galactica.bat-boa.ts.net:/tmp/
ssh root@galactica.bat-boa.ts.net 'LIST=/tmp/galactica.tsv BATCH=6 sh /tmp/probe.sh'
```
Expected: about 36 verdict lines; hermes, ask, radarr, sonarr and jackett must not appear. Runtime is roughly 6 batches × 45 s.

- [ ] **Step 2: Fix every FAIL**

Follow Task 3 Step 3's procedure and mapping, editing the file under `hosts/galactica/services/` that declares the container. Re-probe only the fixed ones by filtering the TSV, e.g. `grep -E '^(name1|name2)	' galactica.tsv > retry.tsv`. Repeat until no FAIL remains.

- [ ] **Step 3: Snapshot and build**

```bash
ssh root@galactica.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" > /tmp/hardening/galactica-before
nix develop -c just build galactica
```

- [ ] **Step 4: Deploy**

Run: `nix develop -c just deploy galactica`
Expected: ends with `Done.`.

- [ ] **Step 5: Verify**

Wait 90 seconds (plex, jellyfin and seafile start slowly), then:
```bash
/tmp/hardening/post-list.sh galactica > /tmp/hardening/galactica-post.tsv
scp /tmp/hardening/galactica-post.tsv /tmp/hardening/post-check.sh root@galactica.bat-boa.ts.net:/tmp/
ssh root@galactica.bat-boa.ts.net 'LIST=/tmp/galactica-post.tsv sh /tmp/post-check.sh; systemctl --failed --no-legend'
ssh root@galactica.bat-boa.ts.net "podman ps --format '{{.Names}}' | sort" | diff /tmp/hardening/galactica-before - && echo "same containers"
```
Expected: every line `OK`, no failed units, `same containers`. Fix failures as in Task 3 Step 6.

- [ ] **Step 6: Commit and push**

```bash
git add hosts/galactica
git commit -m "feat(galactica): run containers with dropped capabilities"
nix flake check --no-build 2>&1 | grep -iE "error" || echo "eval clean"
git push origin master
```
Expected: `eval clean`, push succeeds. CI's `build.yml` then builds all hosts and `checks.yml` runs the new check.

- [ ] **Step 7: Clean up**

```bash
for h in pegasus basestar galactica; do ssh root@$h.bat-boa.ts.net 'rm -f /tmp/*.tsv /tmp/probe.sh /tmp/post-check.sh; podman ps -a --format "{{.Names}}" | grep -c "^capprobe-" || true'; done
rm -rf /tmp/hardening
```
Expected: `0` for each host.
