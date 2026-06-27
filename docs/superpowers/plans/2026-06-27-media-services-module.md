# media.services Unified Service Option — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `mkService` function helper with a discoverable, type-checked
`media.services.<name>` NixOS option, and add a declarative `database.postgres` dependency that
auto-provisions postgres (db, role, trust `pg_hba`, systemd ordering, connection env) with zero
per-service boilerplate.

**Architecture:** A new module `modules/media/services.nix` defines the `media.services` option
and *lowers* each entry into the existing, unchanged `media.containers.<name>` /
`media.gateway.services.<name>` plumbing — the same branch logic `__mkService.nix` uses today.
`database.postgres` adds postgres provisioning via NixOS `ensureDatabases`/`ensureUsers` + a
`trust` pg_hba line scoped to the podman bridge subnet (the TCP analogue of peer auth). All 37
existing `mkService` call sites are migrated to the option and `__mkService.nix` is deleted.

**Tech Stack:** Nix, NixOS module system, flake-parts + haumea auto-loading, podman
(`virtualisation.oci-containers`), Caddy gateway, sops-nix, Colmena/`just` deploys.

---

## Testing approach (read before starting)

This is a NixOS configuration repo — there is no unit-test runner for module logic. The
equivalent of TDD here is **behavior-preservation via `nix eval` baselines plus full host
builds**:

- **Baseline harness (Task 1):** capture `nix eval` JSON snapshots of the *derived* config that
  must not change across the refactor — the OCI container definitions and the Caddy gateway
  service set — for every affected host. After each migration batch, re-capture and `diff`. An
  empty diff = behavior preserved. Non-empty diff must be explained (only the intentional
  database-related changes are allowed to differ, and only in the DB tasks).
- **Build verification:** `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
  must succeed for each affected host. `basestar` is aarch64 and builds via the remote builder
  automatically inside `nix develop`.
- All commands assume you are inside `nix develop` (run `nix develop -c <cmd>` if not).

Affected hosts: **galactica** (x86_64), **basestar** (aarch64), **pegasus** (x86_64),
**raider** (x86_64 — enables some `constellation.*` service modules).

Helper scripts live in `scratch/media-services/` (git-ignored working dir; create it, do not
commit it).

---

## File Structure

- **Create:** `modules/media/services.nix` — the `media.services` option, its lowering into
  `media.containers`/`media.gateway.services`, and the `database.postgres` provisioner. Single
  responsibility: the user-facing service declaration surface.
- **Delete:** `modules/media/__mkService.nix` — function helper, fully replaced.
- **Modify:** all 37 service files (`hosts/*/services/*.nix`, `modules/services/*.nix`) — drop
  the `mkService` import + `lib.mkMerge` wrapper, write `media.services.<name> = { … }`.
- **Modify:** `hosts/galactica/services/ask.nix`, `hosts/basestar/services/ask.nix`,
  `hosts/galactica/services/bitmagnet.nix`, `hosts/galactica/services/db.nix` — adopt
  `database.postgres` and trim the now-redundant central postgres provisioning.
- **Modify:** `CLAUDE.md` and memory `mkservice-mandatory.md` — describe `media.services` as the
  single entry point.

`modules/media/services.nix` `imports = [ ./containers.nix ]`; `containers.nix` already imports
`gateway.nix` and `config.nix`, so the whole chain loads from one place. (haumea auto-loads
every file under `modules/`, so duplicate imports are deduplicated by the module system — the
explicit import only documents the dependency.)

---

## Task 1: Baseline harness

**Files:**
- Create: `scratch/media-services/capture-baseline.sh`
- Create: `scratch/media-services/diff-baseline.sh`

- [ ] **Step 1: Create the capture script**

```bash
mkdir -p scratch/media-services
cat > scratch/media-services/capture-baseline.sh <<'EOF'
#!/usr/bin/env bash
# Capture nix-eval snapshots of derived config that the refactor must NOT change.
set -euo pipefail
OUT="${1:?usage: capture-baseline.sh <output-subdir>}"
DIR="scratch/media-services/$OUT"
mkdir -p "$DIR"
HOSTS=(galactica basestar pegasus raider)
for h in "${HOSTS[@]}"; do
  echo "capturing $h ..."
  # OCI container definitions (images, env, ports, volumes, extraOptions)
  nix eval --json \
    ".#nixosConfigurations.$h.config.virtualisation.oci-containers.containers" \
    > "$DIR/$h.containers.json" 2>"$DIR/$h.containers.err" || echo "  (containers eval failed; see $h.containers.err)"
  # Gateway service set (port/host/settings/exposeViaTailscale per service)
  nix eval --json \
    ".#nixosConfigurations.$h.config.media.gateway.services" \
    --apply 'svcs: builtins.mapAttrs (n: s: { inherit (s) enable host port exposeViaTailscale; settings = s.settings; }) svcs' \
    > "$DIR/$h.gateway.json" 2>"$DIR/$h.gateway.err" || echo "  (gateway eval failed; see $h.gateway.err)"
done
echo "baseline written to $DIR"
EOF
chmod +x scratch/media-services/capture-baseline.sh
```

- [ ] **Step 2: Create the diff script**

```bash
cat > scratch/media-services/diff-baseline.sh <<'EOF'
#!/usr/bin/env bash
# Diff a freshly-captured snapshot against the original baseline.
set -euo pipefail
A="scratch/media-services/${1:?usage: diff-baseline.sh <baseline-subdir> <new-subdir>}"
B="scratch/media-services/${2:?usage: diff-baseline.sh <baseline-subdir> <new-subdir>}"
rc=0
for f in "$A"/*.json; do
  name="$(basename "$f")"
  if ! diff -u "$f" "$B/$name" >/dev/null 2>&1; then
    echo "=== CHANGED: $name ==="
    diff -u "$f" "$B/$name" || true
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "No differences — behavior preserved."
exit "$rc"
EOF
chmod +x scratch/media-services/diff-baseline.sh
```

- [ ] **Step 3: Capture the pre-refactor baseline**

Run: `nix develop -c bash scratch/media-services/capture-baseline.sh before`
Expected: `scratch/media-services/before/{galactica,basestar,pegasus,raider}.{containers,gateway}.json` exist and are non-empty. If any `.err` file is non-empty, STOP and resolve the eval error before continuing — the baseline must be clean.

- [ ] **Step 4: Confirm `scratch/` is git-ignored**

Run: `git check-ignore scratch/media-services/before/galactica.containers.json && echo IGNORED`
Expected: prints `IGNORED`. If it does not, add `scratch/` to `.gitignore`:

```bash
echo 'scratch/' >> .gitignore
git add .gitignore && git commit -m "chore: ignore scratch working dir"
```

---

## Task 2: Create the `media.services` option + lowering (no database yet)

**Files:**
- Create: `modules/media/services.nix`

- [ ] **Step 1: Write the module**

Create `modules/media/services.nix` with exactly this content:

```nix
# Unified declarative service definitions.
#
# `media.services.<name>` is the single entry point for declaring a service. It
# replaces the former `mkService` function helper: instead of
#   let mkService = import .../__mkService.nix {inherit lib;};
#   in lib.mkMerge [ (mkService "foo" {...}) ];
# a service file is now a plain module:
#   { media.services.foo = {...}; }
#
# Each entry is *lowered* into the existing media.containers.<name> /
# media.gateway.services.<name> options (unchanged underneath). Those two
# options remain implementation/lowering targets and should not be written by
# hand.
{
  self,
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.media.services;
  backend = config.virtualisation.oci-containers.backend;
  # Podman bridge subnet — containers reach host postgres from here.
  podmanSubnet = "10.88.0.0/16";

  # Lower a single media.services.<name> entry into the underlying options.
  lowerService = name: svc: let
    settings = {inherit (svc) bypassAuth cors funnel insecureTls;};
    # Extras only the caller can know about — auto-created gateway entries from
    # media.containers don't set host or exposeViaTailscale.
    gatewayExtras =
      optionalAttrs svc.tailscaleExposed {exposeViaTailscale = true;}
      // optionalAttrs (svc.host != null) {host = mkForce svc.host;};

    base =
      if svc.container != null
      then
        mkMerge [
          {
            media.containers.${name} =
              {
                listenPort = svc.port;
                inherit (svc) image watchImage;
                inherit settings;
              }
              // optionalAttrs (svc.cmd != null) {cmd = svc.cmd;}
              // svc.container;
          }
          (mkIf (gatewayExtras != {}) {
            media.gateway.services.${name} = gatewayExtras;
          })
        ]
      else {
        media.gateway.services.${name} =
          gatewayExtras
          // optionalAttrs (svc.port != null) {port = svc.port;}
          // {settings = mkDefault settings;};
      };
  in
    base;
in {
  imports = [./containers.nix];

  options.media.services = mkOption {
    default = {};
    description = ''
      Unified declarative service definitions. The single supported way to
      declare a service; lowers into media.containers / media.gateway.services.
    '';
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        port = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Service port. Required for container services; null = auto-assigned for gateway-only.";
        };
        image = mkOption {
          type = types.str;
          default = "ghcr.io/linuxserver/${name}";
          description = "Container image. Defaults to the LinuxServer.io image for the service name.";
        };
        container = mkOption {
          # The body is validated downstream by the media.containers submodule;
          # keep it permissive here to avoid duplicating that option set.
          type = types.nullOr (types.attrsOf types.anything);
          default = null;
          description = "Container body (forwarded into media.containers.<name>). null = gateway-only.";
        };
        cmd = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Container command.";
        };
        host = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Gateway host override (e.g. VPN namespace IP). Lowered with mkForce.";
        };
        bypassAuth = mkOption {
          type = types.bool;
          default = false;
          description = "Skip Authelia for this service.";
        };
        cors = mkOption {
          type = types.bool;
          default = false;
          description = "Enable CORS headers for this service.";
        };
        funnel = mkOption {
          type = types.bool;
          default = false;
          description = "Expose publicly via Tailscale Funnel.";
        };
        insecureTls = mkOption {
          type = types.bool;
          default = false;
          description = "Backend serves a self-signed cert; skip TLS verification.";
        };
        tailscaleExposed = mkOption {
          type = types.bool;
          default = false;
          description = "Create a dedicated <name>.bat-boa.ts.net node via tsnsrv.";
        };
        watchImage = mkOption {
          type = types.bool;
          default = false;
          description = "Poll the registry and restart the container on a new image.";
        };
      };
    }));
  };

  config = mkMerge (mapAttrsToList lowerService cfg);
}
```

- [ ] **Step 2: Verify the module evaluates (no call sites use it yet)**

Run: `nix develop -c nix eval '.#nixosConfigurations.galactica.config.media.services' --apply 'builtins.attrNames'`
Expected: `[ ]` (empty list — option exists, nothing declared yet). No eval error.

- [ ] **Step 3: Verify all hosts still build (the new module is inert)**

Run: `nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link`
Expected: builds successfully (the option is defined but unused, so nothing changes).

- [ ] **Step 4: Commit**

```bash
git add modules/media/services.nix
git commit -m "feat(modules): add media.services unified service option"
```

---

## Task 3: Add `database.postgres` provisioning to `media.services`

**Files:**
- Modify: `modules/media/services.nix`

- [ ] **Step 1: Add the `database` option to the service submodule**

In `modules/media/services.nix`, inside the service submodule's `options = { … }`, add a
`database` option *after* `watchImage`. Because the db/role name defaults to the service name,
the option is built inside the submodule where `name` is in scope:

```nix
        database = mkOption {
          default = {};
          description = "Declarative database dependencies for this service.";
          type = types.submodule {
            options = {
              postgres = mkOption {
                default = {};
                description = ''
                  Provision a local PostgreSQL database + role for this service,
                  reachable from the container over the podman bridge with trust
                  auth (passwordless). Set to true for defaults, or an attrset to
                  override the database/role name.
                '';
                # `true` -> { enable = true; }
                type = types.coercedTo types.bool (b: {enable = b;}) (types.submodule {
                  options = {
                    enable = mkOption {
                      type = types.bool;
                      default = false;
                      description = "Whether to provision postgres for this service.";
                    };
                    name = mkOption {
                      type = types.str;
                      default = name;
                      description = "Database and role name. Defaults to the service name.";
                    };
                  };
                });
              };
            };
          };
        };
```

- [ ] **Step 2: Add the postgres lowering helper**

In the `let … in` of the module (alongside `lowerService`), add a `pgConfig` helper:

```nix
  pgConfig = name: svc: let
    db = svc.database.postgres.name;
  in {
    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      settings.listen_addresses = mkDefault "*";
      ensureDatabases = [db];
      ensureUsers = [
        {
          name = db;
          ensureDBOwnership = true;
        }
      ];
      # TCP analogue of peer auth: passwordless from the podman bridge only.
      authentication = mkAfter "host ${db} ${db} ${podmanSubnet} trust\n";
    };
    # Container starts after its database is up.
    systemd.services."${backend}-${name}" = mkIf (svc.container != null) {
      after = ["postgresql.service"];
      wants = ["postgresql.service"];
    };
    # Inject a passwordless connection into the container env. The container
    # reaches the host postgres via host.containers.internal (podman).
    media.containers.${name}.environment = mkIf (svc.container != null) {
      DATABASE_URL = "postgresql://${db}@host.containers.internal:5432/${db}";
      PGHOST = "host.containers.internal";
      PGPORT = "5432";
      PGDATABASE = db;
      PGUSER = db;
    };
  };
```

- [ ] **Step 3: Include `pgConfig` in the lowering output**

Change the `config` line at the bottom of the module from:

```nix
  config = mkMerge (mapAttrsToList lowerService cfg);
```

to fold in the database config when enabled:

```nix
  config = mkMerge (flatten (mapAttrsToList (name: svc: [
    (lowerService name svc)
    (mkIf svc.database.postgres.enable (pgConfig name svc))
  ]) cfg));
```

- [ ] **Step 4: Verify the option exists and is inert (no consumer yet)**

Run: `nix develop -c nix eval '.#nixosConfigurations.galactica.config.media.services' --apply 'builtins.attrNames'`
Expected: `[ ]`. No eval error (the `database` submodule and `coercedTo` parse correctly).

- [ ] **Step 5: Build galactica (still inert)**

Run: `nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link`
Expected: builds successfully.

- [ ] **Step 6: Commit**

```bash
git add modules/media/services.nix
git commit -m "feat(modules): add declarative database.postgres to media.services"
```

---

## Migration recipe (read before Tasks 4–7)

Every migration follows the same mechanical transformation. Two file shapes exist.

**Shape A — plain service file** (most `hosts/*/services/*.nix`):

Before:
```nix
{self, config, lib, ...}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    (mkService "foo" { port = 1234; container = { … }; bypassAuth = true; })
    { sops.secrets."foo-env" = {}; }   # any extra raw config block
  ]
```

After:
```nix
{config, lib, ...}: {
  media.services.foo = { port = 1234; container = { … }; bypassAuth = true; };
  sops.secrets."foo-env" = {};         # raw blocks move to the top-level config
}
```

Transformation rules:
1. Delete the `let mkService = import …; in` binding.
2. Delete the `lib.mkMerge [ … ]` wrapper.
3. Each `(mkService "NAME" { ARGS })` becomes `media.services.NAME = { ARGS };`.
4. Each bare `{ … }` block in the old `mkMerge` list becomes top-level attributes of the
   returned set (merge by hand — they are plain NixOS config).
5. Drop now-unused function args from the header (`self` if it was only used for the import;
   keep `pkgs`/`config`/`lib` if still referenced). Keep `self` if still used elsewhere in the
   file (e.g. another `import "${self}/…"`).
6. If multiple blocks set the same attribute path (rare), combine them with `lib.mkMerge` at
   that path only.

**Shape B — constellation option module** (`modules/services/*.nix`): these define
`options.constellation.<x>.enable` and wrap services in `config = lib.mkIf cfg.enable
(lib.mkMerge [ … ])`.

Before:
```nix
{config, lib, self, ...}: let
  cfg = config.constellation.mediaStreaming;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "…";
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "jellyfin" { … })
    (mkService "plex" { … })
  ]);
}
```

After:
```nix
{config, lib, ...}: let
  cfg = config.constellation.mediaStreaming;
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "…";
  config = lib.mkIf cfg.enable {
    media.services.jellyfin = { … };
    media.services.plex = { … };
  };
}
```
(If `config` had extra raw blocks beyond the `mkService` calls, keep `lib.mkMerge` and turn each
`mkService` call into a `{ media.services.NAME = { … }; }` entry.)

**Per-batch verification loop (run after every task below):**
1. `nix develop -c bash scratch/media-services/capture-baseline.sh after`
2. `nix develop -c bash scratch/media-services/diff-baseline.sh before after`
   Expected: `No differences — behavior preserved.` (Until the DB tasks, migration is pure
   renaming — the lowered output is byte-identical, so the diff MUST be empty. A non-empty diff
   means a transcription error; fix it before committing.)
3. `nix develop -c nix build '.#nixosConfigurations.<host>.config.system.build.toplevel' --no-link`
   for each host touched in the batch.

---

## Task 4: Migrate single-call plain service files

**Files (Shape A, exactly one `mkService` call, no DB):** apply the Shape-A recipe to each.

- Modify: `hosts/basestar/services/yarr.nix`
- Modify: `hosts/basestar/services/vault.nix`
- Modify: `hosts/basestar/services/webui.nix`
- Modify: `hosts/basestar/services/finance-tracker.nix`
- Modify: `hosts/basestar/services/search.nix`
- Modify: `hosts/basestar/services/ntfy.nix`
- Modify: `hosts/galactica/services/cinephage.nix`
- Modify: `hosts/galactica/services/cloud-sync.nix`
- Modify: `hosts/galactica/services/develop.nix`
- Modify: `hosts/galactica/services/linkding.nix`
- Modify: `hosts/galactica/services/rqbit.nix`
- Modify: `hosts/galactica/services/stashfin.nix`
- Modify: `hosts/galactica/services/immich.nix`
- Modify: `hosts/galactica/services/seafile.nix`
- Modify: `hosts/galactica/services/qbittorrent-vpn.nix`
- Modify: `hosts/galactica/services/transmission-vpn.nix`
- Modify: `hosts/galactica/services/yarr.nix`
- Modify: `hosts/galactica/services/search.nix`
- Modify: `hosts/galactica/services/vault.nix`
- Modify: `hosts/pegasus/services/yarr.nix`
- Modify: `hosts/pegasus/services/transmission.nix`

- [ ] **Step 1: Apply the Shape-A recipe to each file above**

Worked example — `hosts/galactica/services/linkding.nix`:

Before (current content):
```nix
{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."linkding-env" = {};}

    (mkService "linkding" {
      port = 9090;
      image = "ghcr.io/sissbruecker/linkding:latest";
      bypassAuth = true; # linkding has its own auth; browser extension/REST API need direct access
      tailscaleExposed = true;
      container = {
        exposePort = 9090;
        configDir = "/etc/linkding/data";
        environmentFiles = [
          config.sops.secrets."linkding-env".path
        ];
      };
    })
  ]
```

After:
```nix
{
  config,
  lib,
  ...
}: {
  sops.secrets."linkding-env" = {};

  media.services.linkding = {
    port = 9090;
    image = "ghcr.io/sissbruecker/linkding:latest";
    bypassAuth = true; # linkding has its own auth; browser extension/REST API need direct access
    tailscaleExposed = true;
    container = {
      exposePort = 9090;
      configDir = "/etc/linkding/data";
      environmentFiles = [
        config.sops.secrets."linkding-env".path
      ];
    };
  };
}
```

Note: `lib` is still in the header but no longer referenced in this particular file — leave it;
unused module args are harmless and removing every one is churn. Remove only `self` when it was
solely for the `mkService` import. (`ntfy.nix` keeps `config`; it has a second raw block with
`services.ntfy-sh` — fold that block in as top-level attrs.)

- [ ] **Step 2: Format**

Run: `nix develop -c just fmt`
Expected: files reformatted in place, no errors.

- [ ] **Step 3: Behavior-preservation check**

Run:
```bash
nix develop -c bash scratch/media-services/capture-baseline.sh after
nix develop -c bash scratch/media-services/diff-baseline.sh before after
```
Expected: `No differences — behavior preserved.`

- [ ] **Step 4: Build affected hosts**

Run (each must succeed):
```bash
nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.basestar.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.pegasus.config.system.build.toplevel' --no-link
```
Expected: all build.

- [ ] **Step 5: Commit**

```bash
git add hosts/basestar/services/ hosts/galactica/services/ hosts/pegasus/services/
git commit -m "refactor(modules): migrate single-call service files to media.services"
```

---

## Task 5: Migrate multi-call plain service files

**Files (Shape A, multiple `mkService` calls and/or extra raw blocks):**
- Modify: `hosts/galactica/services/ai.nix` (4 calls + a `create-podman-ai-network` systemd block)
- Modify: `hosts/galactica/services/auth.nix` (3 calls)
- Modify: `hosts/galactica/services/misc.nix` (4 calls)
- Modify: `hosts/galactica/services/home.nix` (3 calls)
- Modify: `hosts/galactica/services/files.nix` (3 calls)
- Modify: `hosts/galactica/services/media.nix` (6 calls)
- Modify: `hosts/pegasus/services/media.nix` (5 calls)

- [ ] **Step 1: Apply the Shape-A recipe, converting each `mkService` call to a `media.services.<name>` entry and folding raw blocks into the top-level config**

Worked example — the structure of `hosts/galactica/services/ai.nix` after migration (keep each
service's args verbatim; only the wrapper changes). Note `self` and `pkgs` are still needed
(the systemd block uses `pkgs`; `self` is dropped since the only use was the `mkService`
import):

```nix
{
  config,
  pkgs,
  lib,
  ...
}: let
  vars = config.media.config;
in {
  media.services.ollama-api = {
    port = 11434;
    bypassAuth = true;
  };

  media.services.n8n = {
    port = 5678;
    image = "n8nio/n8n:latest";
    tailscaleExposed = true;
    container = {
      exposePort = 5678;
      configDir = null;
      network = "ai";
      environment = {
        N8N_DIAGNOSTICS_ENABLED = "false";
        N8N_PERSONALIZATION_ENABLED = "false";
        N8N_HOST = "n8n.${vars.domain}";
        WEBHOOK_URL = "https://n8n.${vars.domain}/";
        OLLAMA_HOST = "ollama:11434";
      };
      volumes = [
        "${vars.configDir}/n8n/n8n_storage:/home/node/.n8n"
        "${vars.configDir}/n8n/backup:/backup"
        "${vars.configDir}/n8n/shared:/data/shared"
      ];
    };
  };

  media.services.qdrant = {
    image = "qdrant/qdrant";
    container = {
      configDir = null;
      network = "ai";
      volumes = ["qdrant_storage:/qdrant/storage"];
      extraOptions = ["--publish=6333:6333"];
    };
  };

  media.services.ollama = {
    image = "ghcr.io/ava-agentone/ollama-intel:latest";
    container = {
      configDir = null;
      network = "ai";
      devices = ["/dev/dri/card0" "/dev/dri/renderD128"];
      environment = {
        OLLAMA_HOST = "0.0.0.0:11434";
        OLLAMA_NUM_GPU = "999";
        OLLAMA_KEEP_ALIVE = "5m";
        OLLAMA_CONTEXT_LENGTH = "8192";
        OLLAMA_NUM_PARALLEL = "1";
        ONEAPI_DEVICE_SELECTOR = "level_zero:0";
        ZES_ENABLE_SYSMAN = "1";
        SYCL_CACHE_PERSISTENT = "1";
      };
      volumes = ["${vars.configDir}/ollama:/root/.ollama"];
      extraOptions = [
        "--publish=11434:11434"
        "--group-add=303"
        "--group-add=26"
        "--shm-size=4g"
      ];
    };
  };

  systemd.services.create-podman-ai-network = {
    description = "Create Podman AI Network";
    after = ["podman.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "create-podman-ai-network" ''
        ${pkgs.podman}/bin/podman network create ai || true
      '';
    };
  };
}
```

For each other file, preserve every service's args exactly; only convert the wrapper. Where two
`media.services.<name>` entries plus raw blocks coexist, they are all just attributes of the
single returned set — no `mkMerge` needed unless two definitions target the *same* attribute
path.

- [ ] **Step 2: Format**

Run: `nix develop -c just fmt`
Expected: no errors.

- [ ] **Step 3: Behavior-preservation check**

Run:
```bash
nix develop -c bash scratch/media-services/capture-baseline.sh after
nix develop -c bash scratch/media-services/diff-baseline.sh before after
```
Expected: `No differences — behavior preserved.`

- [ ] **Step 4: Build affected hosts**

Run (each must succeed):
```bash
nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.pegasus.config.system.build.toplevel' --no-link
```
Expected: all build.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/ hosts/pegasus/services/
git commit -m "refactor(modules): migrate multi-call service files to media.services"
```

---

## Task 6: Migrate constellation option modules

**Files (Shape B):**
- Modify: `modules/services/home-apps.nix` (4 calls)
- Modify: `modules/services/network-tools.nix` (3 calls)
- Modify: `modules/services/media-automation.nix` (9 calls)
- Modify: `modules/services/media-streaming.nix` (4 calls)
- Modify: `modules/services/media-apps.nix` (3 calls)

- [ ] **Step 1: Apply the Shape-B recipe to each file**

Worked example — `modules/services/media-streaming.nix`:

Before (head):
```nix
{config, lib, self, ...}: let
  cfg = config.constellation.mediaStreaming;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "media streaming services (Plex, Jellyfin, Stash, Kavita)";
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "jellyfin" { port = 8096; container = { … }; bypassAuth = true; tailscaleExposed = true; })
    (mkService "plex" { … })
    # … two more
  ]);
}
```

After:
```nix
{config, lib, ...}: let
  cfg = config.constellation.mediaStreaming;
  vars = config.media.config;
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "media streaming services (Plex, Jellyfin, Stash, Kavita)";
  config = lib.mkIf cfg.enable {
    media.services.jellyfin = { port = 8096; container = { … }; bypassAuth = true; tailscaleExposed = true; };
    media.services.plex = { … };
    # … two more
  };
}
```
Keep each service's args verbatim. Drop `self` from the header (only used for the import).
Keep `vars` if referenced. If a file's `config` had raw blocks besides `mkService` calls,
retain `lib.mkMerge` and express each service as `{ media.services.NAME = { … }; }`.

- [ ] **Step 2: Format**

Run: `nix develop -c just fmt`
Expected: no errors.

- [ ] **Step 3: Behavior-preservation check (all hosts, since these modules are host-gated)**

Run:
```bash
nix develop -c bash scratch/media-services/capture-baseline.sh after
nix develop -c bash scratch/media-services/diff-baseline.sh before after
```
Expected: `No differences — behavior preserved.` (Hosts that don't enable a given
`constellation.*` module are unaffected; hosts that do must produce identical lowered output.)

- [ ] **Step 4: Build all affected hosts**

Run (each must succeed):
```bash
nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.basestar.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.pegasus.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.raider.config.system.build.toplevel' --no-link
```
Expected: all build.

- [ ] **Step 5: Commit**

```bash
git add modules/services/
git commit -m "refactor(modules): migrate constellation service modules to media.services"
```

---

## Task 7: Migrate remaining single-call container files

**Files (Shape A, single call, container-backed, no DB — these were not in Task 4's list):**
- Modify: `hosts/galactica/services/bitmagnet.nix` — **handled in Task 8** (it is postgres-backed); skip here.
- Modify: `hosts/galactica/services/transmission-vpn.nix` — already in Task 4; skip.

> There are no leftover non-DB single-call files beyond Task 4. This task is a checkpoint: confirm
> every `mkService` user except the postgres-backed ones (`ask.nix`, `bitmagnet.nix`) and the DB
> module file is migrated.

- [ ] **Step 1: Confirm only the expected files still reference `mkService`**

Run: `grep -rl "mkService" hosts/ modules/ | sort`
Expected output is exactly:
```
hosts/basestar/services/ask.nix
hosts/galactica/services/ask.nix
hosts/galactica/services/bitmagnet.nix
modules/media/__mkService.nix
```
If any other file appears, migrate it with the appropriate Shape-A/B recipe, then re-run, format, diff, build, and fold it into the previous commit's batch.

---

## Task 8: Adopt `database.postgres` and trim provisioning

This is the one task that *intentionally* changes the eval baseline (postgres env + ordering),
so its verification uses targeted asserts rather than an empty diff.

**Files:**
- Modify: `hosts/basestar/services/ask.nix`
- Modify: `hosts/galactica/services/ask.nix`
- Modify: `hosts/galactica/services/bitmagnet.nix`
- Modify: `hosts/galactica/services/db.nix`

- [ ] **Step 1: Determine each app's expected DB env var**

The provisioner injects `DATABASE_URL` + `PGHOST/PGPORT/PGDATABASE/PGUSER`. Confirm each app
consumes one of these:
- **morphic (`ask`)** reads `DATABASE_URL`. Confirm via: `grep -ri "DATABASE_URL\|POSTGRES" hosts/basestar/services/ask.nix hosts/galactica/services/ask.nix` and the morphic image docs. If it needs a different name, add that var explicitly in the service's `container.environment` (it merges with the injected vars).
- **bitmagnet** reads `POSTGRES_HOST`/`POSTGRES_NAME`/`POSTGRES_USER` (not `DATABASE_URL`). Inspect current `bitmagnet.nix` to see which env it already sets and keep those names — set them in `container.environment` pointing at `host.containers.internal` / the db name; the injected `PG*`/`DATABASE_URL` are harmless extras.

- [ ] **Step 2: Migrate `hosts/basestar/services/ask.nix` to `database.postgres`**

Before (the relevant parts): an inline `services.postgresql` block (ensureDatabases/ensureUsers
+ scram `pg_hba` + a `morphic-db-password` sops secret + `postStart ALTER USER` + a manual
`systemd.services."${backend}-ask"` ordering). Replace the whole file with the migrated form —
note the **scram → trust** change means the `morphic-db-password` secret and the `ALTER USER`
postStart are deleted entirely:

```nix
{
  config,
  lib,
  ...
}: {
  sops.secrets."morphic-env" = {};

  # Morphic — ask.arsfeld.one. Reaches the host's system PostgreSQL (provisioned
  # via database.postgres, trust auth over the podman bridge) and native SearXNG
  # via host.containers.internal.
  media.services.ask = {
    port = 3000;
    image = "ghcr.io/miurla/morphic:latest";
    bypassAuth = true; # auth at the Cloudflare edge
    tailscaleExposed = true; # ask.bat-boa.ts.net
    watchImage = true;
    container = {
      configDir = null; # morphic keeps state in postgres, not /config
      environmentFiles = [config.sops.secrets."morphic-env".path];
    };
    database.postgres = {name = "morphic";};
  };
}
```

If morphic needs `DATABASE_URL` to include a password, STOP — trust auth issues a passwordless
URL; verify morphic accepts a passwordless `postgresql://morphic@host/morphic`. Postgres `trust`
ignores any password, and libpq accepts a URL with no password, so this works; if the app
*requires* a non-empty password string, keep a dummy in the URL by setting
`container.environment.DATABASE_URL` explicitly. Confirm by reading morphic's connection code or
testing post-deploy (Step 6).

- [ ] **Step 3: Reconcile `hosts/galactica/services/ask.nix`**

Galactica's `ask.nix` is the primary home (basestar's is a failover copy). Apply the identical
`database.postgres = {name = "morphic";}` migration there and remove its inline postgres
provisioning + `morphic-db-password` secret + `ALTER USER` postStart. (The `morphic` database
already exists in `db.nix` — Step 5 removes the duplicate central declaration.)

- [ ] **Step 4: Migrate `hosts/galactica/services/bitmagnet.nix`**

Read the file; it currently relies on the central `db.nix` `bitmagnet` database (trust auth
already). Convert its `mkService` call to `media.services.bitmagnet` (Shape A) and add
`database.postgres = true;` (db/role name `bitmagnet` = service name). Keep bitmagnet's existing
`POSTGRES_*` env vars in `container.environment` (bitmagnet does not read `DATABASE_URL`).

- [ ] **Step 5: Trim the now-duplicated central declarations in `db.nix`**

In `hosts/galactica/services/db.nix`, remove from the `services.postgresql` block the entries
now owned by `database.postgres` — `bitmagnet` and `morphic` (both their `ensureUsers` entry and
`ensureDatabases` entry and their `host … trust` lines in `authentication`). **Leave**
`openarchiver` (not yet migrated), the `immich`/`openarchiver` `identMap`+peer lines, the entire
`services.mysql`/MariaDB section, the redis server, and `services.postgresqlBackup` /
`services.mysqlBackup` untouched.

Because `media.services.*.database.postgres` re-adds `bitmagnet`/`morphic` to
`ensureDatabases`/`ensureUsers`/`authentication` via `mkAfter`, the net set of postgres
databases is unchanged — `postgresqlBackup.databases = config.services.postgresql.ensureDatabases`
still covers them.

- [ ] **Step 6: Verify the DB wiring (targeted asserts, not an empty diff)**

Run and check each:
```bash
# morphic env contains a postgres connection
nix develop -c nix eval --json '.#nixosConfigurations.basestar.config.virtualisation.oci-containers.containers.ask.environment' | grep -o '"DATABASE_URL":"[^"]*"'
# expected: "DATABASE_URL":"postgresql://morphic@host.containers.internal:5432/morphic"

# ask container is ordered after postgresql
nix develop -c nix eval --json '.#nixosConfigurations.basestar.config.systemd.services."podman-ask".after'
# expected: a list containing "postgresql.service"

# the full set of provisioned postgres databases is unchanged on galactica
nix develop -c nix eval --json '.#nixosConfigurations.galactica.config.services.postgresql.ensureDatabases' --apply 'builtins.sort (a: b: a < b)'
# expected: same set as the pre-refactor baseline (bitmagnet, morphic, openarchiver)

# trust pg_hba line is present for morphic
nix develop -c nix eval --raw '.#nixosConfigurations.galactica.config.services.postgresql.authentication' | grep "host morphic morphic 10.88.0.0/16 trust"
# expected: the line prints
```
Expected: each command prints the described output. (The container `.err`/eval for `ask` on
galactica vs basestar: run the morphic checks against whichever host actually deploys it —
basestar in the current failover state.)

- [ ] **Step 7: Build affected hosts**

Run (each must succeed):
```bash
nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link
nix develop -c nix build '.#nixosConfigurations.basestar.config.system.build.toplevel' --no-link
```
Expected: both build.

- [ ] **Step 8: Commit**

```bash
git add hosts/basestar/services/ask.nix hosts/galactica/services/ask.nix hosts/galactica/services/bitmagnet.nix hosts/galactica/services/db.nix
git commit -m "refactor(galactica,basestar): provision postgres via media.services database.postgres"
```

---

## Task 9: Delete `__mkService.nix` and update docs/memory

**Files:**
- Delete: `modules/media/__mkService.nix`
- Modify: `CLAUDE.md`
- Modify: `/home/arosenfeld/.claude/projects/-home-arosenfeld-Code-nixos/memory/mkservice-mandatory.md`

- [ ] **Step 1: Confirm no remaining references**

Run: `grep -rn "mkService\|__mkService" hosts/ modules/ --include=*.nix`
Expected: **no output** (every consumer migrated).

- [ ] **Step 2: Delete the helper**

```bash
git rm modules/media/__mkService.nix
```

- [ ] **Step 3: Update `CLAUDE.md`**

In the "Service and Network Architecture" section, replace the `mkService` description and the
example with the `media.services.<name>` option. Key edits:
- Heading "`mkService` is the only way to declare a service" → "`media.services.<name>` is the only way to declare a service".
- Replace the `let mkService = import …; in lib.mkMerge [ (mkService "myapp" {…}) ]` example with:

```nix
{config, lib, ...}: {
  media.services.myapp = {
    port = 8080;
    image = "ghcr.io/.../myapp";
    bypassAuth = true;
    tailscaleExposed = true;
    cors = true;
    funnel = true;
    insecureTls = true;
    host = "192.168.15.1";
    container = {
      exposePort = 38080;
      mediaVolumes = true;
      configDir = "/config";
      cmd = ["worker" "run"];
      devices = ["/dev/dri:/dev/dri"];
      network = "ai";
      environment = {FOO = "bar";};
      environmentFiles = [config.sops.secrets.foo.path];
      volumes = ["/host:/container"];
      extraOptions = ["--add-host=host.containers.internal:host-gateway"];
    };
    watchImage = true;
    database.postgres = true; # provision + wire a local postgres db/role (trust auth)
  };
}
```
- Update the surrounding prose: it now writes to `media.services.<name>`, which lowers into
  `media.containers`/`media.gateway.services` (still implementation details). Replace mentions of
  "the `mkService` helper at `modules/media/__mkService.nix`" with "the `media.services` option
  at `modules/media/services.nix`".
- In "Adding New Services", change "Define the service using the `mkService` helper" → "Define
  the service with `media.services.<name>`", and "Use `mkService` the same way" likewise.
- Add a short bullet documenting `database.postgres` (auto-provisions db/role/trust-pg_hba/
  systemd-ordering/connection-env; mysql is not yet supported).

- [ ] **Step 4: Update the `mkservice-mandatory` memory**

Rewrite `/home/arosenfeld/.claude/projects/-home-arosenfeld-Code-nixos/memory/mkservice-mandatory.md`
so the fact reflects the new entry point. Keep the frontmatter `name: mkservice-mandatory` (the
MEMORY.md pointer references it) but update `description` and body to:
- every service MUST be declared via `media.services.<name>` (the option at
  `modules/media/services.nix`); never hand-write `media.containers`, `media.gateway.services`,
  or `virtualisation.oci-containers` blocks.
- postgres dependencies use `database.postgres`; mysql is still manual (deferred).

Update the matching line in `MEMORY.md` if its hook text says "mkService".

- [ ] **Step 5: Format and build a representative host**

Run:
```bash
nix develop -c just fmt
nix develop -c nix build '.#nixosConfigurations.galactica.config.system.build.toplevel' --no-link
```
Expected: no errors; builds.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md modules/media/
git commit -m "docs(modules): document media.services as the single service entry point; remove mkService"
```
(The memory files live outside the repo; they are saved separately, not via `git`.)

---

## Task 10: Final full-fleet verification

- [ ] **Step 1: Re-capture and diff the full baseline one last time**

Run:
```bash
nix develop -c bash scratch/media-services/capture-baseline.sh final
nix develop -c bash scratch/media-services/diff-baseline.sh before final
```
Expected: the ONLY differences are on `galactica`/`basestar` and are confined to the
database-related env (`DATABASE_URL`/`PG*` added to `ask`/`bitmagnet`) — i.e. exactly the Task 8
changes. Every other host and service is byte-identical. Inspect the diff and confirm there are
no surprises.

- [ ] **Step 2: Build every affected host**

Run (each must succeed):
```bash
for h in galactica basestar pegasus raider; do
  echo "=== $h ==="
  nix develop -c nix build ".#nixosConfigurations.$h.config.system.build.toplevel" --no-link || { echo "BUILD FAILED: $h"; break; }
done
```
Expected: all four build.

- [ ] **Step 3: Confirm `mkService` is fully gone**

Run: `grep -rn "mkService\|__mkService" . --include=*.nix`
Expected: **no output**.

- [ ] **Step 4: Optional — dry-run a deploy to a tier1 host**

Run: `just dry-run galactica`
Expected: shows the expected activation changes (postgres ordering/env for `ask`/`bitmagnet`,
otherwise no functional service changes). Do **not** deploy as part of this plan unless the user
asks.

---

## Self-Review (completed by plan author)

- **Spec coverage:** §1 unified option → Tasks 2,4,5,6,7,9. §2 database.postgres → Tasks 3,8.
  §3 redis-not-reinvented → no task (intentional non-goal). §4 auto systemd ordering → Task 3
  (`pgConfig` sets `after`/`wants`). §5 big-bang migration + delete `__mkService.nix` → Tasks
  4–9. Non-goals (planka, socket peer-auth, mysql, backups) → respected in Task 8 Step 5.
- **Placeholder scan:** all code steps contain full code; migration is a precise recipe with a
  worked example per file shape and an exhaustive per-file checklist; no "TBD"/"similar to".
- **Type consistency:** `media.services.<name>` option names (`port`, `image`, `container`,
  `cmd`, `host`, `bypassAuth`, `cors`, `funnel`, `insecureTls`, `tailscaleExposed`,
  `watchImage`, `database.postgres.{enable,name}`) are identical across Tasks 2,3,8,9.
  `pgConfig`/`lowerService` helper names match between Task 2 and Task 3. The lowering mirrors
  `__mkService.nix` exactly, so Task 4–6 migrations are pure renames (empty-diff verified).
