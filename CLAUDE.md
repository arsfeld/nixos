# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal NixOS configuration repository that manages multiple machines using Nix Flakes and flake-parts. It includes configurations for servers (galactica, basestar), embedded devices (R2S, Raspberry Pi), and desktop systems (raider, blackbird).

## Key Commands

### Development Environment
```bash
nix develop                    # Enter dev shell (required for most operations)
just fmt                       # Format all Nix files with alejandra
just build <hostname>          # Build a host config locally
```

### Deployment

```bash
just deploy galactica           # Deploy to one host
just deploy galactica basestar  # Deploy to multiple hosts in parallel
just deploy @tier1              # Deploy a whole tier
just boot @tier1                # Boot activation (next reboot)
just test raider                # Activate without changing the boot default
just dry-run @tier1             # Build, then report which units would change
just reboot galactica           # Deploy and reboot (kernel changes)
just info                       # List all known hosts
```

`just deploy` runs in two phases. Phase 1 is `nix-fast-build` over `.#deployTargets`:
parallel evaluation via nix-eval-jobs, parallel build, and an inline push to niks3 via
`--niks3-server`. Phase 2 activates each host in parallel with `nixos-rebuild
--store-path`, which skips evaluation and build entirely, and `--use-substitutes`, so each
target pulls its own closure from `cache.arsfeld.dev` instead of receiving NARs over
Tailscale.

`--niks3-server` folds upload results into nix-fast-build's exit code, so a niks3 outage
aborts the deploy before anything activates. That is the intended trade — the closures are
already built locally, so a re-run once the server is back costs nothing, whereas a
silently-skipped push leaves behind a closure no target can substitute. In the other
direction, `--use-substitutes` degrades rather than fails: a target that cannot substitute
— an untrusted key, an empty cache — receives the closure over SSH.

Two consequences of that flag are easy to hit and hard to diagnose from the error alone:

- **raider is the deploy driver.** The flag lives in `_apply`, so it binds all six recipes
  (`deploy`, `boot`, `test`, `dry-run`, `deploy-all`, `reboot`), and phase 1 needs a push
  token. `NIKS3_AUTH_TOKEN_FILE` is set only on raider
  (`hosts/raider/configuration.nix`). Run any of these from another machine and phase 1
  aborts *after* the full build with `auth token is required …`, which names niks3 and not
  the deploy driver. Note this includes `just dry-run`, so the read-only inspection recipe
  now depends on the write path being reachable. To deploy from elsewhere, either export
  `NIKS3_AUTH_TOKEN_FILE` at a copy of the token or use `just nr-deploy <host>`, which
  skips phase 1 entirely.
- **`just deploy` cannot bootstrap niks3 itself** — phase 1 would abort pushing to the
  server it is in the middle of creating. Bootstrap that one case with a plain
  `nixos-rebuild switch --flake .#basestar --target-host root@basestar.bat-boa.ts.net`.

Phase 1 is a barrier: nothing activates unless every named host builds — including in
`deploy-all`, which names all nine, so a single host that fails to build blocks the whole
fleet. That is a real behavior change from colmena, and intended. An *unreachable* host is
a different case: phase 1 never contacts the targets, so it builds fine and only its own
phase-2 activation fails while the others still activate. The exception is `basestar`,
which is the aarch64 remote builder — if it is down, nothing aarch64 builds at all.

Deploying the machine you are sitting on is handled automatically — Tailscale SSH
cannot authenticate a host connecting to itself, so `_apply` drops `--target-host` and
uses local `sudo` when the target matches `hostname`.

nixos-rebuild fallback (single host, sequential): `just nr-deploy <host>`,
`just nr-boot <host>`, `just nr-test <host>`.

**The invariant:** every deploy path must evaluate `.#nixosConfigurations` and must
never `import inputs.nixpkgs` to build its own package set. Doing so loses the flake's
revision and yields `…-26.05pre-git` derivations that differ from the dated ones CI
builds and caches, so substitution never hits. That is what colmena did, and why it was
removed. `just deploy`, the CI matrix (`ciMatrix`) and `weekly-deploy` all evaluate the
same attribute today; keep it that way.

All hosts are reached via Tailscale: `<hostname>.bat-boa.ts.net`.

### Weekly Automation

- **GitHub `Weekly Update`** (Sun 00:00 UTC): `nix flake update`, builds tier-1, commits
  `flake.lock` to master. Gated on tier-1 only — a broken octopi will not block the lock.
  It sends no notification of its own: GitHub-hosted runners hit Cloudflare's managed
  challenge (HTTP 403) on `ntfy.arsfeld.one`, so a `curl` from CI can never post there.
- **galactica `weekly-deploy`** (Sun 06:00 UTC): pulls master, then runs `nixos-rebuild
  switch --flake <repo>#<host>` once per tier-1 host (remotes over Tailscale SSH first,
  galactica itself last) with `max-jobs = 0` so it never builds — it deploys the same
  `nixosConfigurations` attribute CI caches, which is why substitution always
  hits. Verifies failed units and backup freshness over
  Tailscale SSH, checks `flake.lock`'s age (escalates past 14 days stale — the signal
  that CI stopped landing updates), and posts one ntfy summary. State in
  `/var/lib/weekly-deploy/`. Run it early with `sudo systemctl start weekly-deploy`.

Two things about this that are not obvious and cost real time to rediscover:

- **It can only deploy a commit CI has already built.** `self` is part of every system
  closure, so *any* tracked change shifts all three hosts' toplevel paths. A commit CI
  has not built is absent from the cache, and `max-jobs = 0` then fails rather than building.
  This is what the per-host CI job gate enforces; it is working as intended, not a bug.
- **After changing `weekly-deploy.nix`, install it once by hand** (`just deploy galactica`).
  A broken deployer cannot deploy its own fix, and a stale unit will happily run old logic
  against a new commit — the tell is a summary describing machinery the current code no
  longer contains.

The binary cache is two endpoints, and only one of them is a server:

- **Read** — `https://cache.arsfeld.dev` is the R2 bucket `nix-cache` with a custom domain
  attached. Attaching the domain is what makes objects publicly readable; there is no
  separate toggle and the managed `r2.dev` domain stays disabled. No machine of ours is in
  this path, so nothing we run can make a substitution fail. **Never add an R2 lifecycle
  rule to this bucket** — niks3's GC deletes objects from its own Postgres reference table,
  and a rule deleting them behind its back leaves narinfos pointing at absent NARs, which
  fails only at deploy time.
- **Write** — `https://niks3.arsfeld.dev` is niks3 on basestar behind Caddy, reached by a
  **grey-cloud** (DNS-only) A record to `168.138.71.109`. Clients ask it for presigned R2
  URLs and PUT NARs straight to R2; the server only sees JSON. Grey-cloud is not optional:
  proxied records serve GitHub-hosted runners a managed challenge (HTTP 403), the same
  reason CI can never post to `ntfy.arsfeld.one`. The usual argument for proxying —
  Cloudflare's 100 MB body limit — does not apply, because no NAR traverses this hostname.

CI pushes every closure it builds with `niks3 push --pin <host>`, one pin per host name,
retargeted on each push so the previous closure ages out normally. That is every host in
`ciMatrix` — all nine — on a push to master, and the tier-1 three when `update.yml` calls
the workflow with its `hosts` input. Pinned closures are exempt from the 30-day GC window,
and object GC walks reachability from surviving closures, so everything beneath a pinned
toplevel survives too.

What that buys is specifically the `max-jobs = 0` invariant: the closure `weekly-deploy`
needs can never age out from under it. What actually expires is un-pinned material —
chiefly the derivations raider auto-uploads via its post-build hook, which is most of the
bucket's growth. If it grows past expectations, shorten `olderThan` rather than disabling
auto-upload; the pins are what make a shorter window safe.

One consequence worth knowing before you touch basestar: it is now in CI's push path.
Deploying or rebooting it during a `build.yml` run fails that run's push. It fails safe —
job red, tier-1 gate skips the commit — and `just deploy @tier1` is unaffected, because
phase 1 finishes every push before phase 2 activates anything, and niks3 is socket-activated
so connections queue across its own restart rather than being refused.

attic is gone. It was the binary cache until niks3 replaced it on 2026-08-21 (`60dc149`,
`194bfe3`), sat frozen as a read-only fallback for 17 days, and was retired entirely on
2026-09-07: substituter and `system:` key removed from every host and from CI, the argocd
app and namespace on can-1 torn down, the `ATTIC_TOKEN` secret deleted, all four
`attic.arsfeld.dev` DNS records removed, and the R2 buckets `attic`, `attic-data` and
`attic-cache` deleted.

`attic.arsfeld.dev` still *resolves*, and still answers HTTP 200, and both are expected:
the zone has a proxied `*.arsfeld.dev` wildcard CNAME, so the name falls through to it and
lands on the zone's catch-all. What comes back is an empty body with no `StoreDir`, which
is not a usable binary cache. Neither a successful `dig` nor a 200 is evidence attic
survived — check for a DNS record of its own, or for `StoreDir` in the response body.

The measurement that justified it: of 60 paths sampled at random from raider's live
closure, `cache.arsfeld.dev` held 60 and attic held 2 — **zero** that attic had and R2
did not. Every narinfo in `nix-cache` is signed `cache.arsfeld.dev-1`, so nothing anywhere
depended on attic's key. Full workings in
`docs/superpowers/specs/2026-09-06-attic-retirement-design.md`.

**There is no fallback binary cache any more.** A path missing from `cache.arsfeld.dev`
falls through to `cache.nixos.org` and then to a local rebuild. That is harmless
everywhere except `weekly-deploy`, which runs under `max-jobs = 0` where a miss is a hard
failure — which is exactly what CI's `niks3 push --pin <host>` exists to prevent. Treat
the pins as load-bearing, not as an optimization.

### Testing Changes
```bash
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel
```

### Secret Management

```bash
nix develop -c sops secrets/sops/<hostname>.yaml    # Create/edit host secrets
nix develop -c sops --decrypt secrets/sops/basestar.yaml  # View decrypted
nix develop -c sops updatekeys secrets/sops/<file>.yaml  # Re-encrypt after key changes
```

Configured via `.sops.yaml`. All hosts use `constellation.sops.enable = true`. Use standard `sops.secrets` options. Common/shared secrets: `config.constellation.sops.commonSopsFile`.

### Infrastructure (OpenTofu via terranix)

The Oracle Cloud tenancy behind basestar and the three in-use Cloudflare DNS
zones (`arsfeld.dev`, `arsfeld.one`, `rosenfeld.one`) are managed as code under
`infra/`, written as terranix Nix modules rather than HCL. 52 resources are
under management: 46 `cloudflare_dns_record` plus 6 Oracle resources (VCN,
internet gateway, default route table, default security list, subnet,
instance).

```bash
just tf plan      # anything tofu accepts: plan, apply, state list, ...
just tf apply
```

`just tf` rebuilds `config.tf.json` from `.#infra-config`, links it into the
gitignored `infra/.work`, decrypts `secrets/sops/infra.yaml` into the
environment, and runs an OpenTofu resolved from `.#tofu` — never from PATH,
because the ambient `tofu` carries no provider mirror and would fetch
providers from the registry instead.

For running `tofu` or `oci` directly instead of through `just tf` — ad-hoc
`state list`, `oci compute instance get`, and the like — use `nix develop
.#infra`. Both tools live in that shell rather than `devShells.default`
because CI enters the default shell on every host it builds and never
touches either one; keeping them out saves it roughly 1.2 GiB of closure it
would otherwise pull for nothing.

Things worth knowing before touching it:

- **Everything here was imported, not created.** The `import` blocks are kept
  after adoption rather than deleted: they are the record of which real
  object each resource adopted, and they make rebuilding lost state an apply
  rather than an archaeology exercise.
- **The VCN's route table and security list are its implicit defaults, not
  independent objects.** Oracle creates a default route table, security
  list, and DHCP options set alongside every VCN and doesn't support
  destroying them separately from it, so they're adopted as
  `oci_core_default_route_table` and `oci_core_default_security_list`,
  addressed by `manage_default_resource_id` rather than `vcn_id`. The
  generic `oci_core_route_table`/`oci_core_security_list` types model a
  create/destroy lifecycle Oracle doesn't support for these — use the
  `default_*` types only for the one object Oracle created automatically; a
  *second* route table or security list on this VCN would need the generic
  types instead.
- **`ingress_security_rules` is a set, not a list, as far as the provider is
  concerned.** A duplicate rule in the Nix produces zero diff — `tofu plan`
  reports `No changes.` whether the file declares 25 rules or 26. This isn't
  theoretical: the live list once genuinely held a duplicate
  `51821-51830/udp` rule (both real, both transcribed faithfully from
  discovery), an unrelated apply collapsed the pair to one on Oracle's side,
  and `infra/oci/network.nix` kept asserting a rule count that no longer
  matched reality until someone counted rules by hand and noticed. **A clean
  plan is not proof the rule count in the file matches the rule count on the
  wire** — this is the single least obvious trap in the whole system. If a
  rule count matters, count it directly against `oci network security-list
  get`, don't infer it from `tofu plan`.
- **The instance, VCN, and subnet carry `prevent_destroy`.** A plan that
  would delete basestar fails to generate. `just tf plan -destroy` erroring
  out naming `prevent_destroy` is the expected behaviour, not a bug.
- **The instance ignores `source_details`.** basestar was infected onto a
  stock Oracle image years ago; Oracle retires image OCIDs on its own
  schedule, and an unguarded configuration would read that retirement as
  "replace the machine".
- **basestar's public IP, `168.138.71.109`, is ephemeral, not reserved.**
  There's no `oci_core_public_ip` resource anywhere in `infra/` — the VNIC
  just carries the address via `assign_public_ip`. This one address is the
  content of five managed A records across all three zones — the `arsfeld.dev`
  apex (proxied), plus `niks3.arsfeld.dev`, `seed.arsfeld.dev`,
  `mail.arsfeld.one` and the `rosenfeld.one` apex (all grey-cloud). Losing it
  breaks CI's cache push, the seed node and mail routing for both domains at
  once.

  Two things about that are easy to get backwards, and were, in this file,
  until they were checked against Oracle's documentation:

  - **Stop/start does not change it.** Oracle: "When you stop an instance, its
    ephemeral public IPs remain assigned to the instance." The address is lost
    when the *instance* goes away — termination, or a VNIC delete/recreate —
    not on a reboot or a stop. The `prevent_destroy` guard on the instance is
    therefore already the main mitigation.
  - **Reserving cannot keep this address.** Oracle: "After you create a given
    public IP object, you can't change which type it is" — an ephemeral public
    IP cannot be converted to a reserved one with the same value. Reserving
    means allocating a *new* address, unassigning the ephemeral, assigning the
    reserved one, and updating all five A records: a planned cutover with four
    unproxied records to propagate, not a free hardening step. That is why it
    was left undone, and the reason is the cutover cost, not oversight.
- **`oci_core_default_dhcp_options` exists on the VCN but is deliberately
  left unmanaged.** Its OCID is recorded in a comment in
  `infra/oci/network.nix` for whoever eventually adopts it.
- **Nothing here is zone-authoritative.** The config declares 50 individual
  `cloudflare_dns_record` resources, not a resource type that owns the zone
  as a whole, so OpenTofu only ever touches records present in its config or
  state — it cannot see, let alone delete, a record created out-of-band (say,
  by adding a tunnel hostname in the Zero Trust dashboard). The real hazards
  run the other way: the zone files silently stop being a complete picture
  of the zone, and if a dashboard change touches a name that *is* managed,
  the next apply reverts it. Add new hostnames to
  `infra/dns/arsfeld-one.nix` instead, or import them afterwards.
- **Committing to `infra/` stages a real infrastructure change for whoever
  next runs `just tf apply` — not necessarily you.** This already happened
  once: a concurrent session committed a new UDP ingress rule (iroh relay
  discovery) to `network.nix`, and a later, unrelated task's apply picked it
  up and pushed it live with no apply record of its own beyond that task's.
  There's no review gate between a commit landing and an apply picking it
  up — read what a plan actually names before applying it, not just its
  summary line.
- **State lives in the R2 bucket `tfstate`**, with locking via conditional
  PUT. Never add an R2 lifecycle rule to it — R2 has no object versioning
  (Cloudflare's S3-compatibility table lists `GetBucketVersioning` as
  unimplemented), so a deleted or corrupted state object has no earlier
  version to fall back to. The actual recovery path is the one this design
  already built: the retained `import` blocks make state lost outright
  rebuildable with a plan and an apply, not an archaeology exercise.
- **`secrets/sops/infra.yaml` has only the user key as a recipient.** No host
  reads it; OpenTofu runs from a workstation.
- Provider versions come from nixpkgs, not from `required_providers`. There
  is deliberately no version constraint in the Nix — the plugin mirror is
  the pin.
- **The `_N` suffixes on sibling records (same name, multiple values, e.g.
  `mx_arsfeld_one_1`/`_2`) are frozen ordinals from an ASCII sort of
  `content` at import time, not indices to keep in sync.** Inserting a new
  record that would sort earlier does not renumber the existing ones —
  doing that by hand would change resource addresses, which OpenTofu reads
  as destroy-and-create. Give a newly added sibling the next unused number
  regardless of where it would sort.

### Available Hosts
- **galactica** - Main server: media services, databases, backups. Hosts internal services on `*.arsfeld.one` via cloudflared tunnel (wildcard ingress)
- **basestar** - Public-facing server (BSG Cylon Basestar): hosts services on `*.arsfeld.dev` (blog, plausible, planka, siyuan)
- **raider** - Desktop workstation: GNOME, gaming, development
- **router** - Custom network device (no constellation modules, standalone config)
- **r2s** - ARM-based router (NanoPi R2S)
- **raspi3** - Raspberry Pi 3
- **blackbird** - ASUS ROG Zephyrus G14 laptop (BSG Blackbird — custom stealth ship)
- **pegasus** - Secondary server (BSG Battlestar Pegasus)
- **octopi** - OctoPrint device

### Host Tiers

Hosts are grouped into deployment tiers, defined in `flake-modules/hosts.nix` as the `tiers` attribute (also exposed as the `tiers` flake output):

- **tier1** - `galactica`, `basestar`, `raider`. Always on, should always be deployed. Deploy the whole tier with `just deploy @tier1`.

To add or change a tier, edit `tiers` in `flake-modules/hosts.nix`; the `@tier` selectors in the justfile and the README table follow from it. The CI build matrix (`.github/workflows/build.yml`) is derived from the `ciMatrix` flake output (all discovered hosts with auto-detected platform) — it is not tier-gated.

For hardware specs (CPU, RAM, disks), see [HARDWARE.md](HARDWARE.md).

## Architecture Overview

### Flake Structure

The flake uses **flake-parts** to organize outputs into modules under `flake-modules/`:
- **`lib.nix`** - Core utilities: `mkLinuxSystem`, overlays, `baseModules`, `homeManagerModules`. Uses **haumea** to recursively auto-load all files from `modules/` and `packages/` directories.
- **`hosts.nix`** - Auto-discovers hosts by scanning `hosts/` for directories with `configuration.nix`. Automatically includes `disko-config.nix` if present.
- **`deploy.nix`** - `deployTargets`: each host's system closure, the attribute `just deploy` builds
- **`dev.nix`** - Development shell, formatter, git hooks, custom packages
- **`checks.nix`** - Flake checks (router NixOS test)
- **`images.nix`** - System image generators (SD cards, kexec)

### Module Auto-Discovery

All `.nix` files under `modules/` are loaded automatically by haumea - no explicit imports needed. To add a new module, create a file in `modules/` (or a subdirectory) and it will be available to all hosts. Hosts then selectively enable modules via `constellation.<module>.enable = true`.

### Constellation Modules (`modules/constellation/`)

Opt-in feature modules that hosts compose. Key modules:

| Module | Purpose |
|--------|---------|
| `common.nix` | Base config: Nix flakes, caches, SSH, Tailscale, Avahi |
| `users.nix` | User accounts, SSH keys, sudo |
| `sops.nix` | sops-nix infrastructure (age keys, default paths) |
| `services.nix` | **Central service registry**: ports, auth, CORS, Tailscale exposure |
| `media.nix` | **Container orchestration**: Plex, *arr, Stash, Nextcloud, etc. |
| `podman.nix` / `docker.nix` | Container runtimes |
| `backup.nix` | Automated rustic/restic backups |
| `vpn-exit-nodes.nix` | Tailscale exit nodes via AirVPN/Gluetun |
| `gnome.nix` / `cosmic.nix` / `niri.nix` | Desktop environments |
| `development.nix` | Dev tools (Docker, Node, Python, Go, Rust) |
| `gaming.nix` | Gaming environment |
| `metrics-client.nix` / `logs-client.nix` | Observability agents |
| `observability-hub.nix` | Central Prometheus/Loki hub |
| `home-assistant.nix` | Home automation |
| `virtualization.nix` / `project-vms.nix` | KVM/libvirt VMs |

### Media Configuration Variables (`modules/media/config.nix`)

Shared variables consumed by media services via `config.media.config`:
- `configDir` = `/var/data` - Service config/data directory
- `storageDir` = `/mnt/storage` - Large media files (**galactica host only**, not available on basestar)
- `dataDir` = `/mnt/storage` - Primary data directory
- `puid`/`pgid` = `5000` - UID/GID for all media services
- `user`/`group` = `"media"` - Service user
- `domain` = `"arsfeld.one"` - Primary domain
- `tsDomain` = `"bat-boa.ts.net"` - Tailscale domain

### Service and Network Architecture

#### `media.services.<name>` is the only way to declare a service
All service declarations on galactica/basestar go through the `media.services.<name>` option defined in `modules/media/services.nix`. It lowers into `media.containers.<name>` for containers (which auto-populates `media.gateway.services.<name>`) and/or `media.gateway.services.<name>` for native/gateway-only services. Do **not** write to `virtualisation.oci-containers.containers`, `media.gateway.services`, or `media.containers` by hand — those are implementation details and bypassing `media.services` will silently miss the standardized PUID/PGID/TZ env, the auto-tmpfiles config dir, the gateway entry, and image-watching.

```nix
{config, lib, ...}: {
  media.services.myapp = {
    port = 8080; # required for containers; optional for gateway-only (auto-assigned)
    image = "ghcr.io/.../myapp"; # defaults to ghcr.io/linuxserver/<name>
    bypassAuth = true; # skip Authelia
    tailscaleExposed = true; # creates a *.bat-boa.ts.net node via tsnsrv
    cors = true; # enable CORS
    funnel = true; # public via Tailscale Funnel
    insecureTls = true; # backend has self-signed cert
    host = "192.168.15.1"; # gateway-host override (e.g. VPN namespace IP)
    container = {
      # omit for gateway-only services
      exposePort = 38080; # host port (defaults to nameToPort <name>)
      mediaVolumes = true; # mount /media + /files
      configDir = "/config"; # default; set null to skip the auto config-dir mount
      cmd = ["worker" "run"]; # container command
      devices = ["/dev/dri:/dev/dri"];
      network = "ai"; # podman network
      environment = {FOO = "bar";};
      environmentFiles = [config.sops.secrets.foo.path];
      volumes = ["/host:/container"];
      extraOptions = ["--add-host=host.containers.internal:host-gateway"];
    };
    watchImage = true; # poll registry & restart on new image
    database.postgres = true; # provision + auto-wire a local postgres db/role (trust auth)
  };
}
```

Set `database.postgres = true` (or `database.postgres = {name = "otherdb";}`) to auto-provision a local PostgreSQL database + role for the service, reachable from the container over the podman bridge with passwordless trust auth. It adds the db/role, the `pg_hba` trust line, systemd ordering after `postgresql.service`, and injects `DATABASE_URL`/`PG*` into the container env — no sops secret, `ALTER USER`, or manual `pg_hba` needed. MySQL/MariaDB auto-provisioning is not yet supported (services needing it keep their manual setup).

The `media.services` settings (`bypassAuth`, `cors`, `funnel`, `insecureTls`) are forwarded to `media.gateway.services.<name>.settings`. `tailscaleExposed` and `host` are caller-only and don't have container equivalents.

For containers without a gateway entry (e.g. headscale-ui, qdrant), set `container.extraOptions = ["--publish=HOST:CONTAINER"]` and leave `port = null`. `media.services` then registers the container without auto-creating a gateway service.

#### Container Module (`modules/media/containers.nix`)
Backs `media.containers.*`. Auto-creates the matching `media.gateway.services.<name>` entry when `listenPort != null`, mounts `${configDir}/<name>:<container.configDir>`, sets PUID/PGID/TZ from `media.config`, and wires image-watching when `watchImage = true`.

**Volume path rules:**
- Use `${vars.storageDir}` for media, `${vars.configDir}` for config

#### Gateway (`modules/media/gateway.nix`)
Caddy reverse proxy consuming service definitions. Generates TLS configs, error pages, tsnsrv integration.

#### DNS & Routing
- `*.arsfeld.one` — internal services hosted on **galactica**, routed via Cloudflare → galactica's cloudflared tunnel (wildcard ingress)
- `*.arsfeld.dev` — public services hosted on **basestar** (blog, plausible, planka, siyuan)
- `*.bat-boa.ts.net` — Tailscale-only access (or public via Funnel)

### Remote Builders
`basestar` (aarch64-linux) serves as remote builder. When in `nix develop`, aarch64 packages build on basestar automatically via `nix-builders.conf`.

### Directory Structure
- `hosts/` - Per-machine configs (auto-discovered by `flake-modules/hosts.nix`)
- `modules/` - All NixOS modules (auto-loaded by haumea)
  - `constellation/` - Opt-in feature modules
  - `media/` - Media stack (config, gateway, components)
- `packages/` - Custom Nix derivations (auto-loaded by haumea)
- `home/` - Home Manager config (`home.nix` for user `arosenfeld`)
- `secrets/` - Encrypted secrets (`sops/*.yaml` managed by sops-nix)
- `flake-modules/` - Flake-parts modules
- `just/` - Justfile submodules (blog, secrets, docs)

## Host & Container Conventions

These are standing preferences — follow them, and push back rather than violate them:

- **No per-app firewall rules.** Never add `networking.firewall.interfaces.<x>.allowedTCPPorts` or per-service allow rules in service modules. Hosts rely on the host firewall's base allowlist (`22/80/443`) plus the upstream OCI/cloud firewall for external access. `media.services` is the contract for a service — keep firewall plumbing out of service files.
- **Container → host services:** trust the container bridge once at the host level (`networking.firewall.trustedInterfaces = ["podman0"]`), not individual ports. Containers reach host services via `host.containers.internal` (podman).
- **Keep fail2ban.** Don't disable the host firewall to work around container networking — fail2ban depends on it. Find another way.
- **No host networking for containers.** Don't use `--network=host` (the existing `planka.nix` usage is a mistake, not a pattern to copy).
- **Prefer the system PostgreSQL** with a dedicated database/role (see `planka.nix`) over a containerized/custom postgres unless absolutely necessary.
- **Container backend is podman** on galactica/pegasus/basestar (basestar migrated from docker 2026-06-27). Rootful (`sudo podman ps`; units `podman-<name>`). Use `config.virtualisation.oci-containers.backend` / `${backend}-<name>` — never hardcode a runtime.
- **Don't over-engineer.** Reach for the simplest thing that works; avoid speculative plumbing.

## Adding New Services

Always declare services with `media.services.<name>` (see "Service and Network Architecture" above). The pattern below applies to both containers and native NixOS services — only the `container` attr differs.

### `*.arsfeld.one` services (on galactica)

1. Create a service file in `hosts/galactica/services/` and add it to `default.nix` imports.
2. Define the service with `media.services.<name>`.
3. Galactica's wildcard cloudflared tunnel routes traffic automatically; the gateway entry is created by `media.services`.

### `*.arsfeld.dev` services (on basestar)
1. Create a service file in `hosts/basestar/services/` and add it to `default.nix` imports.
2. Use `media.services.<name>` the same way; basestar uses dedicated Caddy vhosts for `arsfeld.dev` subdomains.

## Commit Message Format

Conventional commits required: `<type>(<scope>): <subject>`

**Types**: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`
**Scopes**: hostname (`raider`, `galactica`, `basestar`), or `secrets`, `modules`, `home`

Never mention Claude in commit messages or author.

## CI/CD (.github/workflows/)

- **build.yml** - Builds every host in `ciMatrix` (all nine) and pushes each closure to niks3 with `--pin <host>`; `update.yml` calls it with just the tier-1 three
- **format.yml** - Checks formatting with alejandra (fails if unformatted, run `just fmt` locally)
- **update.yml** - Weekly flake input updates with automatic build testing, commits flake.lock if all hosts build
