# Constellation backrest module
#
# Per-host wrapper around the `backrest` daemon (web UI + scheduler wrapping
# restic). Each host that enables this module runs its own Backrest instance,
# manages its own repos/plans, and posts failures to ntfy.arsfeld.one/backups.
#
# Design notes:
#   - Runs as root (matches rustic/restic convention; needs read on /var/lib
#     /home /root and in some cases /).
#   - Config.json is mutated by the daemon at runtime (repo guids, modno,
#     sync.identity), so it can't live in the Nix store. ExecStartPre runs a
#     jq merge script that applies the Nix template while preserving those
#     runtime-written fields. Treat the Backrest web UI as read-only; any
#     structural config change goes through Nix.
#   - No secrets in the rendered config. Passwords are read by restic from
#     RESTIC_PASSWORD_FILE (set in repo env). Ntfy credentials are read by
#     the failure hook's shell command from env (loaded via EnvironmentFile).
#     That's why there's no envsubst / secret-templating layer — restic and
#     hook scripts handle their own secret loading.
#   - Backrest's own auth is disabled; Authelia via Caddy fronts the public
#     backrest-<host>.arsfeld.one subdomain. Firewall opens 9898 on tailscale0
#     only — any tailnet device with a valid Tailscale ACL can reach the
#     daemon directly (that ACL is the out-of-repo trust boundary).
#   - BACKREST_RESTIC_COMMAND is hardcoded to nixpkgs restic so Backrest
#     never downloads its own binary into /var/lib.
#   - Uses pkgs-unstable.backrest to track upstream releases faster.
{
  self,
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backrest;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
  };

  clockEnumMap = {
    "local" = "CLOCK_LOCAL";
    "utc" = "CLOCK_UTC";
    "last-run" = "CLOCK_LAST_RUN_TIME";
  };

  # Schedule submodule → Backrest's Schedule oneof. Caller supplies exactly
  # one of {cron, maxFrequencyHours, maxFrequencyDays}.
  renderSchedule = s: let
    base = {clock = clockEnumMap.${s.clock};};
  in
    if s.cron != null
    then base // {cron = s.cron;}
    else if s.maxFrequencyHours != null
    then base // {maxFrequencyHours = s.maxFrequencyHours;}
    else if s.maxFrequencyDays != null
    then base // {maxFrequencyDays = s.maxFrequencyDays;}
    else {disabled = true;};

  # Retention submodule → Backrest's RetentionPolicy.
  # Non-null sub-fields go into policyTimeBucketed; all-null means keep-all.
  renderRetention = r: let
    bucketed = filterAttrs (_: v: v != null) r;
  in
    if bucketed == {}
    then {policyKeepAll = true;}
    else {policyTimeBucketed = bucketed;};

  # Module-level default failure hook. Uses actionCommand (shell) instead
  # of actionWebhook so the ntfy publisher credential stays in
  # EnvironmentFile and never appears in the rendered config.json (the UI
  # renders hook configurations verbatim).
  #
  # Template vars ({{.Event}}, {{.Repo.Id}}, etc.) are expanded by Backrest
  # at hook-fire time. Shell vars ($NTFY_BASIC_AUTH_B64) expand at runtime
  # from the backrest daemon's env (inherited by the exec'd shell).
  defaultFailureHook = {
    conditions = ["CONDITION_ANY_ERROR" "CONDITION_SNAPSHOT_ERROR"];
    actionCommand = {
      command = ''
        #!${pkgs.bash}/bin/bash
        ${pkgs.curl}/bin/curl -sS --fail-with-body -X POST \
          -H "Authorization: Basic $NTFY_BASIC_AUTH_B64" \
          -H "Title: Backrest ${cfg.instance}: {{.Repo.Id}}/{{.Plan.Id}} failed" \
          -H "Tags: floppy_disk,warning" \
          --data-binary '{{.Event}} on {{.Repo.Id}}/{{.Plan.Id}} (host ${cfg.instance}): {{.Error}}' \
          https://ntfy.arsfeld.one/backups
      '';
    };
  };

  renderRepo = name: repo: {
    id = name;
    uri = repo.uri;
    password = ""; # restic reads from RESTIC_PASSWORD_FILE via env below
    env =
      ["RESTIC_PASSWORD_FILE=${toString repo.passwordFile}"]
      ++ repo.env;
    flags = repo.flags;
    autoUnlock = repo.autoUnlock;
    # Without this, Backrest requires a pre-populated guid field
    # (derived from `restic cat config --json`). autoInitialize tells
    # Backrest to initialize new repos and derive the guid from existing
    # ones on first connect — matches how restic's own `init` flag works.
    autoInitialize = true;
  };

  renderPlan = name: plan: {
    id = name;
    repo = plan.repo;
    paths = plan.paths;
    excludes = plan.excludes;
    iexcludes = plan.iexcludes;
    schedule = renderSchedule plan.schedule;
    retention = renderRetention plan.retention;
    backupFlags =
      plan.extraBackupFlags
      ++ (map (f: "--exclude-if-present=${f}") plan.excludeIfPresent);
    hooks =
      if plan.hooks == null
      then [defaultFailureHook]
      else plan.hooks;
  };

  # Pure JSON config — no placeholders, no runtime substitution. Paths to
  # secret files are fine to include; the secrets themselves live in the
  # files, read by restic / hook commands at runtime.
  configAttrs = {
    modno = 0;
    version = 4;
    instance = cfg.instance;
    auth = {disabled = true;};
    repos = mapAttrsToList renderRepo cfg.repos;
    plans = mapAttrsToList renderPlan cfg.plans;
  };

  configTemplate = pkgs.writeText "backrest-config.json" (builtins.toJSON configAttrs);

  # Merge script: apply the Nix template on every start while preserving the
  # fields Backrest writes at runtime (repo guids derived from restic, modno
  # optimistic-lock counter, and the sync identity keypair).
  # On a fresh install the dest doesn't exist yet — just copy.
  mergeConfigScript = pkgs.writeShellScript "backrest-merge-config" ''
    set -euo pipefail
    DEST=/var/lib/backrest/config.json
    if [ ! -f "$DEST" ]; then
      install -m 0600 ${configTemplate} "$DEST"
      exit 0
    fi
    ${pkgs.jq}/bin/jq -s '
      .[0] as $tpl | .[1] as $live |
      $tpl
      | .modno = ($live.modno // 0)
      | .repos = (.repos | map(
          . as $r |
          ($live.repos // [] | map(select(.id == $r.id)) | first) as $lr |
          if $lr.guid then . + {guid: $lr.guid} else . end
        ))
      | if $live.sync then . + {sync: $live.sync} else . end
    ' ${configTemplate} "$DEST" > "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
  '';

  # Per-repo envFiles (rclone creds etc.) flow through to restic via
  # Backrest's env inheritance (the daemon's env is passed to restic).
  repoEnvFiles =
    filter (v: v != null)
    (mapAttrsToList (_: repo: repo.envFile) cfg.repos);

  scheduleType = types.submodule {
    options = {
      cron = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Cron expression (5 fields).";
      };
      maxFrequencyHours = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Minimum hours between runs. Use with clock=last-run for laptops.";
      };
      maxFrequencyDays = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Minimum days between runs.";
      };
      clock = mkOption {
        type = types.enum ["local" "utc" "last-run"];
        default = "local";
        description = "Scheduler clock source. last-run is interval-from-last-success (laptop-friendly).";
      };
    };
  };

  retentionType = types.submodule {
    options = {
      hourly = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      daily = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      weekly = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      monthly = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      yearly = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
    };
  };

  repoType = types.submodule {
    options = {
      uri = mkOption {
        type = types.str;
        description = "Restic repo URI (rest:, rclone:, sftp:, local path).";
      };
      passwordFile = mkOption {
        type = types.path;
        description = "Path to the restic repo password (contents only, no KEY=).";
      };
      env = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra env vars as KEY=value strings passed to restic for this repo.";
      };
      envFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional EnvironmentFile sourced for this repo (e.g. hetzner-webdav-env).";
      };
      flags = mkOption {
        type = types.listOf types.str;
        default = [];
      };
      autoUnlock = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  planType = types.submodule {
    options = {
      repo = mkOption {
        type = types.str;
        description = "Name of a repo defined in constellation.backrest.repos.";
      };
      paths = mkOption {
        type = types.listOf types.str;
      };
      excludes = mkOption {
        type = types.listOf types.str;
        default = [];
      };
      iexcludes = mkOption {
        type = types.listOf types.str;
        default = [];
      };
      excludeIfPresent = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Filenames whose presence excludes the containing directory (renders to --exclude-if-present=).";
      };
      schedule = mkOption {
        type = scheduleType;
      };
      retention = mkOption {
        type = retentionType;
        default = {};
      };
      extraBackupFlags = mkOption {
        type = types.listOf types.str;
        default = [];
      };
      hooks = mkOption {
        type = types.nullOr (types.listOf types.attrs);
        default = null;
        description = "Per-plan hooks. null = use module default failure hook. [] = no hooks.";
      };
    };
  };
in {
  options.constellation.backrest = {
    enable = mkEnableOption "Backrest per-host backup orchestrator";

    package = mkOption {
      type = types.package;
      default = pkgs-unstable.backrest;
      description = "Backrest package (defaults to pkgs-unstable for faster upstream tracking).";
    };

    instance = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "Instance identifier used as restic --host tag and UI header.";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0:9898";
      description = "host:port to bind. Firewall (tailscale0 only) is the primary gate.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open 9898 on tailscale0 so storage's Caddy can proxy the UI.";
    };

    repos = mkOption {
      type = types.attrsOf repoType;
      default = {};
    };

    plans = mkOption {
      type = types.attrsOf planType;
      default = {};
    };
  };

  config = mkIf cfg.enable {
    # `restic-password` is a shared secret (common.yaml). Hosts with
    # repo-specific passwords can declare additional sops.secrets entries
    # and reference them via repos.<name>.passwordFile.
    sops.secrets."restic-password" = {
      sopsFile = config.constellation.sops.commonSopsFile;
    };

    environment.systemPackages = [cfg.package pkgs.restic];

    networking.firewall.interfaces.tailscale0.allowedTCPPorts =
      mkIf cfg.openFirewall [9898];

    systemd.services.backrest = {
      description = "Backrest backup orchestrator";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      path = [pkgs.rclone pkgs.openssh pkgs.coreutils pkgs.curl];

      environment = {
        BACKREST_DATA = "/var/lib/backrest";
        BACKREST_CONFIG = "/var/lib/backrest/config.json";
        BACKREST_PORT = cfg.bindAddress;
        BACKREST_RESTIC_COMMAND = "${pkgs.restic}/bin/restic";
        XDG_CACHE_HOME = "/var/cache/backrest";
      };

      serviceConfig = {
        Type = "simple";
        StateDirectory = "backrest";
        StateDirectoryMode = "0700";
        CacheDirectory = "backrest";
        CacheDirectoryMode = "0700";
        # ntfy-publisher-env provides NTFY_BASIC_AUTH_B64 for the failure hook.
        # Per-repo envFiles (e.g. hetzner-webdav-env) flow through to restic
        # via env inheritance.
        EnvironmentFile =
          [config.sops.secrets."ntfy-publisher-env".path]
          ++ repoEnvFiles;
        # Merge Nix template into live config on every start, preserving
        # repo guids, modno, and sync.identity written by Backrest at runtime.
        ExecStartPre = "${mergeConfigScript}";
        ExecStart = "${cfg.package}/bin/backrest";
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
