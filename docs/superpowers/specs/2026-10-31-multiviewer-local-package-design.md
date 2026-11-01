# multiviewer-for-f1 as a local package

## Problem

The desktop module installs `pkgs.unstable.multiviewer-for-f1`, which is
almost always behind. On 2026-10-31 nixpkgs-unstable carried 2.8.4 while
upstream had shipped 2.13.0, so the weekly `nix flake update` has nothing
newer to pull.

The cause is upstream of us. MultiViewer's release API
(`https://api.multiviewer.app/api/v1/releases/latest`) changed its download
format: each download's `id` is now `null` and URLs have the shape

    https://releases.multiviewer.app/v/<version>/1/<token>/multiviewer_<version>_amd64.deb

nixpkgs' `passthru.updateScript` still reads `id` and writes it into a
`/download/<id>/` URL template, so its automatic bumps stopped silently.

The token is per release, not per request: repeated API calls return the same
URL, and that URL serves the .deb (HTTP 200, ~229 MB). `fetchurl` can pin it.

## Design

### Package

`packages/multiviewer-for-f1/package.nix`: a copy of nixpkgs' derivation,
with these changes:

- Replace the `id` let-binding with `token`. Set
  `src.url = "https://releases.multiviewer.app/v/${version}/1/${token}/multiviewer_${version}_amd64.deb"`.
- Remove `passthru.updateScript` and its `writeScript` input. `update-packages`
  does the bumping.
- Rename inputs to whatever the stable nixpkgs actually exposes (for example
  `xorg.libX11` against `libx11`), because local packages are built with
  stable `pkgs` by the overlay in `modules/flake/lib.nix`.

The by-name loader picks it up, and it shadows nixpkgs' attribute of the same
name in `pkgs`.

Keep everything else nixpkgs does: the dpkg unpack, `autoPatchelfHook`, the
wrapper and the runtime libraries. If 2.13.0 needs another library, the first
build will report it as an unresolved dependency; add it then.

### Consumer

`modules/_legacy/constellation/desktop.nix`: change
`pkgs.unstable.multiviewer-for-f1` to `multiviewer-for-f1`. The surrounding
list is already inside `with pkgs`, which is how `celluloid` and
`plex-mpv-shim` resolve.

`modules/flake/dev.nix`: the `allowUnfree` comment names only claude-desktop.
Mention this package too, because it is also unfree.

### Updater

In `just update-packages`, add `multiviewer-for-f1` to the default list and
give it its own `case` arm. Like `claude-desktop`, it has no forge that
nix-update can query, so the arm reads the version from the vendor and passes
it with `--version`. The token is the one value nix-update can't derive, so the
arm writes it into the file first:

```bash
multiviewer-for-f1)
  # Not a forge nix-update can query, and the download URL carries a
  # per-release token it cannot derive from the version: take both from
  # the release API, write the token, let nix-update do version + hash.
  url=$(curl -fsSL https://api.multiviewer.app/api/v1/releases/latest \
    | jq -r '.downloads[] | select(.platform == "linux_deb").url')
  v=$(sed -nE 's|.*/v/([^/]+)/1/[^/]+/.*|\1|p' <<<"$url")
  t=$(sed -nE 's|.*/v/[^/]+/1/([^/]+)/.*|\1|p' <<<"$url")
  [ -n "$v" ] && [ -n "$t" ] || { failed+=("$p"); continue; }
  sed -i "s|token = \"[^\"]*\"|token = \"$t\"|" "packages/$p/package.nix"
  cmd+=(--version "$v") ;;
```

`nix-update --flake --build` then updates the version and hash and builds the
package. If the build fails, the loop's `git checkout -- packages/$p` reverts
the token along with everything else. The Saturday "Weekly update" routine
already runs `just update-packages`, so the routine doesn't change.

### Failure modes

- **The API changes shape again.** The two `sed -n …p` calls only print when
  the URL matches, so `v` or `t` comes back empty and the package lands in
  `failed:`. The routine reports `failed:`, so the breakage gets noticed
  instead of silently stalling the way nixpkgs' copy did.
- **A new release needs a new runtime library.** The autoPatchelf build fails
  and the change rolls back. The routine is already told to fix failures in
  `packages/<name>/` or revert them, so it handles this like any other.

## Testing

1. Write the package at 2.13.0 with the current token and hash, then run
   `nix build .#multiviewer-for-f1`. That proves the copied derivation builds
   on stable at the current release.
2. Test the bump path: set `version` to `2.12.0` and `token` to a junk value,
   then run `just update-packages multiviewer-for-f1`. It should restore 2.13.0
   and the real token, build, and report `updated`. Afterwards
   `git diff packages/` should be empty against the step-1 state.
3. Run it again: it reports `current` and changes nothing.
4. Build raider's toplevel, so the consumer resolves to the local package
   (`nix eval .#nixosConfigurations.raider.pkgs.multiviewer-for-f1.version`
   gives 2.13.0). Do this one host at a time, not in parallel.
5. On raider, launch MultiViewer and check that it starts.
