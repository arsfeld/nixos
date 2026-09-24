# Enforce `media.services` as the only writer of the media lower layers

**Date:** 2026-09-24
**Status:** approved design

## Problem

CLAUDE.md says `media.services.<name>` is the only way to declare a service and
that `media.gateway.services` and `media.containers` are lowering targets nobody
writes by hand. Nothing enforces it. Seven gateway entries are written directly:

| File | Entry | Hand-written today |
|------|-------|--------------------|
| `hosts/galactica/services/beszel.nix` | `beszel` | `port = 8090; settings.bypassAuth = true` |
| `hosts/galactica/services/ntfy.nix` | `ntfy` | `port = 2586; settings.bypassAuth = true` |
| `hosts/galactica/services/infra.nix` | `netdata` | `port = 19999; exposeViaTailscale = true` |
| `hosts/galactica/services/infra.nix` | `grafana` | `port = 3010; exposeViaTailscale = true; settings.bypassAuth = true` |
| `hosts/galactica/services/home-assistant.nix` | `hass` | `port = 8123; exposeViaTailscale = true; settings.bypassAuth = true` |
| `hosts/galactica/services/opencloud.nix` | `opencloud` | `port = 9200; exposeViaTailscale = true; settings.bypassAuth = true` |
| `modules/blocky.nix` | `dns` | `port = dnsPort; settings.bypassAuth = true` (dormant: blocky is enabled nowhere) |

Nothing outside `modules/media/` writes `media.containers`.

## Scope

In scope: `media.gateway.services` and `media.containers`.

Out of scope: `virtualisation.oci-containers.containers`. Five modules write it
directly: basestar's planka, siyuan and iroh-relay, and galactica's
isponsorblock and vpn-exit-nodes (the last two disabled). `modules/tsnsrv.nix`
also writes it, legitimately, for sidecars. Moving the five onto
`media.services` would change their units (injected `PUID`/`PGID`/`TZ`, a config-dir
mount, and an `*.arsfeld.one` gateway vhost derived from the port mapping), so it
cannot be verified by hash equality and is a separate project if ever wanted.
`hosts/raider/docker.nix` only reads oci-containers and is not an offender.

## Design

### 1. Migration

Each entry becomes the equivalent `media.services` declaration:

```nix
media.services.grafana = {
  port = 3010;
  tailscaleExposed = true;
  bypassAuth = true;
};
```

For a gateway-only service (`container = null`), `gatewayOf` in
`modules/media/services.nix` lowers to `port`, `exposeViaTailscale = true` (when
`tailscaleExposed`), and `settings = mkDefault {bypassAuth; cors; funnel;
insecureTls;}`. The only difference from the hand-written form is the priority
of `settings`. Its merged value is identical, so every host's toplevel must be
unchanged.

### 2. Guard

`modules/media/services.nix` gains one assertion per lower-layer option. Each
reads `options.<path>.files` (the files that contributed a definition that
survived `mkIf` — or, with none, the file declaring the option's default) and
fails if any file's repo-relative path does not start with `modules/media/`.
The guard started as a per-option allowlist of files permitted to write
`media.gateway.services` and `media.containers`, matched by the suffix
`/modules/media/<file>`; it was replaced by this single prefix rule because on
hosts with no `media.services` entries at all, the option has no definition
surviving `mkIf`, so `.files` attributes its default to the declaring file
(`gateway.nix` / `containers.nix`) instead — and the allowlist wrongly rejected
that default on 7 of the fleet's 10 hosts. The message names each offending
file, with the store prefix stripped, and points at `media.services.<name>`.
Reads are unaffected, because `.files` records only definitions. That covers
glance, auth, pegasus and `modules/constellation/podman.nix`.

Assertions do not enter the system closure, so the guard itself leaves every
hash unchanged.

Rejected alternatives: renaming the options to `media._lowered.*` still leaves
them writable and churns every reader, and an `apply` that throws cannot tell
who wrote a value.

### 3. Docs

- CLAUDE.md, "`media.services.<name>` is the only way to declare a service":
  say the rule for `media.gateway.services` / `media.containers` is enforced by
  an assertion, drop the claim that `virtualisation.oci-containers.containers`
  is covered, and list the five direct oci-containers writers as known
  exceptions.
- The header comment of `modules/media/services.nix`: "should not be written
  by hand" becomes "cannot be written by hand", with a pointer to the assertion.

## Verification

1. **No semantic change.** For all ten hosts (including cylon-link, evaluated
   only), compare `config.system.build.toplevel.drvPath` at the same HEAD with
   and without the change. Raw equality cannot hold, because the flake's own
   source is in every closure. Where paths differ, `nix-diff` must show only
   the source path and the revision it carries. Any difference in a package,
   unit or `/etc` file is a bug in the migration, not an accepted difference.
   Also, galactica's `config.media.gateway.services` JSON must be byte-identical.
2. **Negative check.** Add `checks.x86_64-linux.media-lower-layers-guarded` to
   `flake-modules/checks.nix`. It extends galactica with a probe module
   (`_file = "media-guard-probe"`) writing both `media.gateway.services.probe`
   and `media.containers.probe`, and requires that `config.assertions` holds a
   failing assertion for each option naming the probe. It reads the assertions
   rather than `tryEval`ing the toplevel, so an unrelated eval error cannot pass
   for the guard working. It runs in `checks.yml`.
3. Confirm the negative check fails when the guard is removed. Do this once, by
   hand, before committing.

## Risk

With no semantic change, deploying changes nothing on any live host. The residual
risk is an over-strict assertion that breaks evaluation somewhere, and step 1
catches that before commit, since it evaluates every host.
