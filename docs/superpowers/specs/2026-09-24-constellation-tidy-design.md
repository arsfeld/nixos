# Constellation tidy: host-only modules move to their hosts

## Why

haumea loads every file under `modules/` into every host, and each module waits
behind `constellation.<x>.enable`. That is the right shape for code several
hosts share — nixpkgs itself works this way — but half of `constellation` is
used by exactly one host. For those modules the pattern buys nothing and costs
something: every host evaluates them, the global option namespace advertises
features only one machine can use, and a module nobody enables never looks dead.

The k3s work already hit this and routed around it: its manifests sit in
`hosts/basestar/k8s/` "because `modules/` is haumea-loaded for every host".
This change makes that the rule rather than an exception.

Considered and rejected: switching the shared modules to import-to-enable, and
the flake-parts "dendritic" layout. The remaining shared modules are exactly
what load-all-plus-enable is for, and several read each other's config
(`media-apps` → `pia`, `systemd-email-notify` → `email`, `rustic`/`backrest`/
`weekly-deploy` → `backupNotify`). Explicit imports would add wiring and buy
little.

## The rule

> **Shared modules live in `modules/` and are turned on with an enable flag.
> Code used by one host lives in `hosts/<host>/`, and importing it is what
> turns it on.**

A host-local module keeps an `enable` option only when it is genuinely toggled,
not merely switched on once. Options that carry values (`k3s.domains`,
`pia.consumers`, `immichPixelSync.stagingDirectory`, …) keep their
`constellation.*` names, so no reader changes.

## Inventory

### Deleted (dead)

| File | Evidence |
|---|---|
| `modules/constellation/metrics-client.nix` | No host or module sets `constellation.metrics-client` |
| `modules/constellation/sites/rosenfeld-blog.nix` | No host or module sets `constellation.sites.rosenfeld-blog` |

### Moved

| From | To | `enable` |
|---|---|---|
| `modules/constellation/weekly-deploy.nix` | `hosts/galactica/weekly-deploy.nix` | dropped |
| `modules/constellation/rustic.nix` | `hosts/galactica/backup/rustic.nix` | dropped |
| `modules/constellation/opencloud.nix` | `hosts/galactica/services/opencloud.nix` | dropped |
| `modules/constellation/home-assistant.nix` | `hosts/galactica/services/home-assistant.nix` | dropped |
| `modules/constellation/tablet-sync.nix` | `hosts/galactica/services/tablet-sync.nix` | dropped |
| `modules/constellation/vpn-exit-nodes.nix` | `hosts/galactica/services/vpn-exit-nodes.nix` | top-level dropped; per-node `enable` kept |
| `modules/constellation/immich-pixel-sync/` | `hosts/galactica/services/immich-pixel-sync/` | dropped |
| `modules/constellation/pia.nix` | `hosts/galactica/services/pia.nix` | dropped (and the `enable = true` in `transmission-vpn.nix`) |
| `modules/services/media-apps.nix` | `hosts/galactica/services/media-apps.nix` | dropped |
| `modules/services/media-automation.nix` | `hosts/galactica/services/media-automation.nix` | dropped |
| `modules/services/media-streaming.nix` | `hosts/galactica/services/media-streaming.nix` | dropped |
| `modules/services/home-apps.nix` | `hosts/galactica/services/home-apps.nix` | dropped |
| `modules/services/network-tools.nix` | `hosts/galactica/services/network-tools.nix` | dropped |
| `modules/constellation/k3s.nix` | `hosts/basestar/k3s.nix` | dropped |
| `modules/constellation/sites/` (minus rosenfeld-blog) | `hosts/basestar/sites/` | dropped per site |
| `modules/constellation/project-vms.nix` | `hosts/raider/project-vms.nix` | top-level dropped; per-VM `enable` kept |
| `modules/constellation/docker.nix` | `hosts/raider/docker.nix` | dropped |
| `modules/constellation/media-sync.nix` | `hosts/pegasus/media-sync.nix` | **kept**, still `false` — see below |

`modules/services/` is empty afterwards and is removed.

**media-sync stays off.** The comment in `hosts/pegasus/configuration.nix`
blames "the move", which is over — galactica is back. The real blocker is a bug
in the module: when the remote marker scan fails (galactica unreachable), the
keep set is empty and cleanup deletes every synced directory under
`/mnt/storage/media`. Re-enabling it would re-arm that. Commit 3 rewrites the
comment to name the bug instead of the move; the flag stays `false`, so the
system is unchanged. Re-enabling is follow-up work (below).

### Stays in `modules/`

`common`, `users`, `sops`, `podman`, `backrest`, `netdata-client`,
`virtualization`, `forgejo-runner`, `development`, `desktop`, `gaming` (each
used by 2+ hosts); `email` (router only, but `systemd-email-notify` reads its
defaults); `backup-notify` and `backup-status` (enabled and read by `rustic`,
`backrest` and `weekly-deploy`); `certs/`. The non-constellation modules at the
top of `modules/` (`tsnsrv`, `blocky`, `cloudflared`, `check-stock`,
`systemd-email-notify`) are out of scope.

`rustic` moving to galactica is fine even though it enables
`backupNotify`/`backupStatus`: a host file may set options of a shared module.
The reverse — a shared module reading a host-local option — must not exist
after the move; `media-apps` → `pia` was the one case, and both move together.

## Wiring

Each host imports its new files from the list it already has:
`hosts/galactica/services/default.nix`, `hosts/galactica/backup/default.nix`,
and the `imports` of `hosts/{galactica,basestar,raider,pegasus}/configuration.nix`.
`immich-pixel-sync/` already has a `default.nix`; `hosts/basestar/sites/` gets
a new one importing `arsfeld-dev.nix` and `rosenfeld-one.nix`, so each is a
one-line import (`well-known/` is data, read by path).

Host lines of the form `constellation.<x>.enable = true;` are deleted where the
flag is dropped; where the attrset also carries values, only the `enable` line
goes.

## Commits

In order, each one evaluating every host:

1. `refactor(modules): delete unused metrics-client and rosenfeld-blog`
2. `refactor(modules): move host-only modules into their hosts` — `git mv` plus
   the new import lines, with no edits to the moved files. Keeping this a pure
   rename lets `git log --follow` track each file.
3. `refactor(modules): drop enable flags from host-local modules` — unwrap each
   `mkIf cfg.enable`, delete the option, delete the host's `enable = true`.
4. `docs: document the shared-vs-host module rule` — CLAUDE.md, below.

Only files this change touches are staged. The working tree already carries
unrelated edits (`flake.lock`, `hosts/raider/{configuration,fontconfig}.nix`);
those stay unstaged, and the baseline is evaluated against that same tree so
they cancel out of the comparison.

## Verification

The change must not alter any system. Proof per host, for all ten hosts
(including cylon-link, which evaluates fine on raider without building):

```bash
# before commit 1, and after each of commits 1–3
nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
nix run nixpkgs#nix-diff -- <before.drv> <after.drv>
```

Evaluation only, so nothing needs building. The expected result is identical
`drvPath`s, or — if the flake's own source enters the closure — a `nix-diff`
whose only difference is that source path and the revision string it carries.
Any difference in a package, unit, or `/etc` file is a bug in the change, not
an acceptable side effect, and stops the commit.

`git add -N` new paths before evaluating (flakes see only tracked files).
`just fmt` before each commit.

No deploy is required. Weekly-deploy and CI will pick up the new revision
normally; because nothing but the revision changes, the CLAUDE.md warning
about installing `weekly-deploy.nix` changes by hand does not apply to the
move.

## CLAUDE.md

- Add the rule above under "Module Auto-Discovery", replacing the sentence
  that says every new module goes in `modules/`.
- Rewrite the constellation module table from what remains, dropping
  the stale rows (`services.nix`, `media.nix`, `docker.nix`, `gnome`/`cosmic`/
  `niri`, `metrics-client`, `observability-hub`, `project-vms`, `k3s`,
  `home-assistant`).
- Update every path that moves: `modules/constellation/k3s.nix` (several
  mentions in the k3s section), `weekly-deploy.nix`.

## Out of scope

- Converting remaining value-carrying options of moved modules into plain
  `let` bindings (k3s's options are read from `hosts/basestar/k8s/`, so they
  must stay options anyway).
- Changing any shared module's interface.
- `modules/media/`, which several hosts use.

## Follow-ups

- **Re-enable media-sync on pegasus.** First make cleanup a no-op when the
  marker scan fails, then re-mark the Vault subdirectories the one-off rsync
  created (otherwise the first managed run deletes them), then flip the flag.
- **Stale failover notes.** `hosts/pegasus/services/media.nix:4` and
  `hosts/basestar/services/default.nix:2` still describe galactica as offline;
  check what they configure and retire or reword them.
