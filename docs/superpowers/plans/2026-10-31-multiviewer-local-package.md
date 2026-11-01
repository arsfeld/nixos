# multiviewer-for-f1 Local Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop multiviewer-for-f1 from falling behind by packaging it in this flake and teaching `just update-packages` to bump it from MultiViewer's release API.

**Architecture:** A copy of nixpkgs' derivation under `packages/multiviewer-for-f1/` (auto-loaded by the overlay, shadowing nixpkgs' attribute) whose URL carries a per-release `token`. The desktop module installs the local package instead of `pkgs.unstable`'s. `update-packages` gets a `case` arm that writes the token from the API, then hands version + hash to `nix-update`.

**Tech Stack:** Nix (stdenvNoCC, dpkg, autoPatchelfHook), just/bash, nix-update, curl + jq.

Spec: `docs/superpowers/specs/2026-10-31-multiviewer-local-package-design.md`

## Global Constraints

- Commit straight to `master`; no branches or worktrees.
- The index holds an unrelated staged refactor. **Commit only this plan's paths** with `git commit -m … -- <paths>`; never `git commit -a` or a bare `git commit`. Never `git add` anything outside the listed files.
- Conventional commits, scope `modules` (or `raider` where noted). Never mention Claude.
- A new file is invisible to flakes until `git add`ed (`git add -N` is enough).
- Evaluate/build one host at a time, never in parallel.
- Never build or evaluate `cylon-link`.
- Release API: `https://api.multiviewer.app/api/v1/releases/latest`, download entry `select(.platform == "linux_deb")`.
- Current release (2026-10-31): version `2.13.0`, token `4v6Nh56coT9pCM00V7Cr45AfiwX9PG-F`, hash `sha256-JE5xsOUk2VZ2AdZP9IV9OU3Sm6jnc0hAO66KtwhHn/s=`.

---

### Task 1: Local package and its consumer

**Files:**
- Create: `packages/multiviewer-for-f1/package.nix`
- Modify: `modules/_legacy/constellation/desktop.nix:186`
- Modify: `modules/flake/dev.nix:16-17` (comment only)

**Interfaces:**
- Produces: flake attribute `.#multiviewer-for-f1` and `pkgs.multiviewer-for-f1` on every host. The file contains exactly one line matching `token = "<token>";` and one matching `version = "<version>";` — Task 2's `sed` and `nix-update` rely on both.

- [ ] **Step 1: Confirm the attribute does not resolve locally yet**

Run: `nix eval --raw .#multiviewer-for-f1.version`
Expected: error, `flake … does not provide attribute … multiviewer-for-f1`.

- [ ] **Step 2: Write the package**

`packages/multiviewer-for-f1/package.nix` (nixpkgs' derivation; `id` → `token`, new URL, `writeScript` input and `passthru.updateScript` removed, maintainers dropped):

```nix
# nixpkgs' copy stalls: MultiViewer's release API now returns `id = null` and
# tokenised URLs, which its updateScript can't follow. `just update-packages`
# bumps this one from the API instead.
{
  stdenvNoCC,
  fetchurl,
  lib,
  makeWrapper,
  autoPatchelfHook,
  dpkg,
  alsa-lib,
  at-spi2-atk,
  cairo,
  cups,
  dbus,
  expat,
  ffmpeg,
  glib,
  gtk3,
  libdrm,
  libudev0-shim,
  libxkbcommon,
  libgbm,
  nspr,
  nss,
  pango,
  libxrandr,
  libxfixes,
  libxext,
  libxdamage,
  libxcomposite,
  libx11,
  libxcb,
}: let
  # Per-release download token from the release API; not derivable from the version.
  token = "4v6Nh56coT9pCM00V7Cr45AfiwX9PG-F";
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "multiviewer-for-f1";
    version = "2.13.0";

    src = fetchurl {
      url = "https://releases.multiviewer.app/v/${finalAttrs.version}/1/${token}/multiviewer_${finalAttrs.version}_amd64.deb";
      hash = "sha256-JE5xsOUk2VZ2AdZP9IV9OU3Sm6jnc0hAO66KtwhHn/s=";
    };

    nativeBuildInputs = [
      dpkg
      makeWrapper
      autoPatchelfHook
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      ffmpeg
      glib
      gtk3
      libdrm
      libxkbcommon
      libgbm
      nspr
      nss
      pango
      libx11
      libxcomposite
      libxcb
      libxdamage
      libxext
      libxfixes
      libxrandr
    ];

    dontBuild = true;
    dontConfigure = true;

    unpackPhase = ''
      runHook preUnpack

      # The deb file contains a setuid binary, so 'dpkg -x' doesn't work here
      dpkg --fsys-tarfile $src | tar --extract

      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/share
      mv -t $out/share usr/share/* usr/lib/multiviewer

      makeWrapper "$out/share/multiviewer/multiviewer" $out/bin/multiviewer \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [libudev0-shim]}:\"$out/share/multiviewer\""

      runHook postInstall
    '';

    meta = {
      description = "Unofficial desktop client for F1 TV";
      homepage = "https://multiviewer.app";
      downloadPage = "https://multiviewer.app/download";
      license = lib.licenses.unfree;
      platforms = ["x86_64-linux"];
      mainProgram = "multiviewer";
    };
  })
```

- [ ] **Step 3: Format and make it visible to the flake**

```bash
nix develop -c alejandra packages/multiviewer-for-f1/package.nix
git add -N packages/multiviewer-for-f1/package.nix
```

- [ ] **Step 4: Build it**

Run: `nix build .#multiviewer-for-f1 --no-link --print-out-paths`
Expected: a store path ending `multiviewer-for-f1-2.13.0`. If autoPatchelf reports `could not satisfy dependency libX.so`, add the providing package to the argument list and `buildInputs`, then rebuild.

Then: `ls $(nix build .#multiviewer-for-f1 --no-link --print-out-paths)/bin/multiviewer`
Expected: the wrapper exists.

- [ ] **Step 5: Point the desktop module at it**

In `modules/_legacy/constellation/desktop.nix`, inside the `lib.optionals cfg.multimedia [` list (already under `with pkgs;`):

```nix
          pkgs.unstable.multiviewer-for-f1
```
becomes
```nix
          multiviewer-for-f1
```

- [ ] **Step 6: Update the unfree comment in `modules/flake/dev.nix`**

```nix
      # packages/claude-desktop is unfree; `nix flake check` evaluates every
      # `packages` output and refuses it without this.
```
becomes
```nix
      # packages/claude-desktop and packages/multiviewer-for-f1 are unfree;
      # `nix flake check` evaluates every `packages` output and refuses them
      # without this.
```

- [ ] **Step 7: Verify raider resolves the local copy**

Run: `nix eval --raw .#nixosConfigurations.raider.pkgs.multiviewer-for-f1.version`
Expected: `2.13.0`.

Run: `nice nix build .#nixosConfigurations.raider.config.system.build.toplevel --no-link`
Expected: succeeds. (If it fails on something in the unrelated staged refactor, report it rather than fixing it.)

- [ ] **Step 8: Commit**

```bash
git add packages/multiviewer-for-f1/package.nix
git commit -m "feat(modules): package multiviewer-for-f1 locally at 2.13.0" -- \
  packages/multiviewer-for-f1/package.nix \
  modules/_legacy/constellation/desktop.nix \
  modules/flake/dev.nix
git show --stat HEAD   # exactly these three files
```

---

### Task 2: Bump it from `just update-packages`

**Files:**
- Modify: `justfile` (the `update-packages` recipe: default list ~line 22, `case` ~line 53)

**Interfaces:**
- Consumes: the `token = "…";` and `version = "…";` lines in `packages/multiviewer-for-f1/package.nix` from Task 1.
- Produces: `just update-packages` (no args) covers multiviewer-for-f1; the Saturday routine picks it up unchanged.

- [ ] **Step 1: Make the package stale (the failing test)**

```bash
f=packages/multiviewer-for-f1/package.nix
sed -i 's|token = "[^"]*"|token = "stale"|; s|version = "2.13.0"|version = "2.12.0"|' "$f"
nix build .#multiviewer-for-f1.src --no-link
```
Expected: the build fails (404 or hash mismatch); the package is now behind.

Run: `just update-packages multiviewer-for-f1`
Expected without the arm: `nix-update` can't find a newer version (no forge) or fails; output ends `failed:  multiviewer-for-f1` or `current: multiviewer-for-f1`, and the token is still `stale`. Restore with `git checkout -- "$f"` if the recipe didn't, then re-apply the `sed` above.

- [ ] **Step 2: Add the package to the default list**

```bash
      librepods
    )
```
becomes
```bash
      librepods
      multiviewer-for-f1
    )
```

- [ ] **Step 3: Add the `case` arm** after the `claude-desktop)` arm's `cmd+=(--version "$v") ;;`:

```bash
        # Not a forge nix-update can query, and the download URL carries a
        # per-release token it cannot derive from the version: take both from
        # the release API, write the token, let nix-update do version + hash.
        multiviewer-for-f1)
          url=$(curl -fsSL https://api.multiviewer.app/api/v1/releases/latest \
            | jq -r '.downloads[] | select(.platform == "linux_deb").url')
          v=$(sed -nE 's|.*/v/([^/]+)/1/[^/]+/.*|\1|p' <<<"$url")
          t=$(sed -nE 's|.*/v/[^/]+/1/([^/]+)/.*|\1|p' <<<"$url")
          [ -n "$v" ] && [ -n "$t" ] || { failed+=("$p"); continue; }
          sed -i "s|token = \"[^\"]*\"|token = \"$t\"|" "packages/$p/package.nix"
          cmd+=(--version "$v") ;;
```

- [ ] **Step 4: Run the bump against the stale package**

Run: `just update-packages multiviewer-for-f1`
Expected: output ends with `updated: multiviewer-for-f1`, `failed:  none`.

Run: `git diff -- packages/multiviewer-for-f1`
Expected: empty — token, version and hash are back to the Task 1 values. (If the API has since shipped a newer release, the diff instead shows that newer version/token/hash and the build succeeded; that is also a pass — keep it.)

- [ ] **Step 5: Run it again**

Run: `just update-packages multiviewer-for-f1`
Expected: `current: multiviewer-for-f1`, `git diff -- packages/multiviewer-for-f1` empty.

- [ ] **Step 6: Commit**

```bash
git commit -m "chore(modules): bump multiviewer-for-f1 from its release API in update-packages" -- justfile
# plus packages/multiviewer-for-f1/package.nix only if Step 4 picked up a newer release
git show --stat HEAD
```

---

### Task 3: Hand-off

- [ ] **Step 1:** Do **not** deploy; tell the user raider needs `just deploy raider` (or waits for Saturday's `@tier1` run), then launch MultiViewer to confirm it starts. blackbird gets it on its next deploy.
