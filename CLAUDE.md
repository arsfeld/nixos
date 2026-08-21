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
silently-skipped push leaves behind a closure no target can substitute. It also means
`just deploy` cannot be used to bootstrap niks3 itself; see the note in
`hosts/basestar/services/niks3.nix`. In the other direction, `--use-substitutes` degrades
rather than fails: a target that cannot substitute — an untrusted key, an empty cache —
receives the closure over SSH.

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

CI pushes each tier-1 closure with `niks3 push --pin <host>`. Pinned closures are exempt
from the 30-day GC window, and object GC walks reachability from surviving closures, so
everything beneath a pinned toplevel survives too. That is what makes the window safe: the
closure `weekly-deploy` needs under `max-jobs = 0` can never age out from under it, while
everything else — including every derivation raider auto-uploads via its post-build hook —
expires in a month. If the bucket grows past expectations, shorten `olderThan` rather than
disabling auto-upload.

One consequence worth knowing before you touch basestar: it is now in CI's push path.
Deploying or rebooting it during a `build.yml` run fails that run's push. It fails safe —
job red, tier-1 gate skips the commit — and `just deploy @tier1` is unaffected, because
phase 1 finishes every push before phase 2 activates anything, and niks3 is socket-activated
so connections queue across its own restart rather than being refused.

attic (`attic.arsfeld.dev`, k3s on can-1) is frozen but still running and still listed as a
substituter, so reverting one commit restores a fully populated cache. Retiring it — the
argocd app, the `attic-cache` bucket, the `ATTIC_TOKEN` secret — is a separate later change.

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

- **build.yml** - Builds basestar (aarch64), galactica (x86_64), raider (x86_64) closures and pushes them to niks3, pinned per host
- **format.yml** - Checks formatting with alejandra (fails if unformatted, run `just fmt` locally)
- **update.yml** - Weekly flake input updates with automatic build testing, commits flake.lock if all hosts build
