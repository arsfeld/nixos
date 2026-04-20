# Constellation backrest module
#
# Per-host wrapper around the `backrest` daemon (web UI + scheduler wrapping
# restic). Each host that enables this module runs its own Backrest instance,
# manages its own repos/plans, and posts failures to ntfy.arsfeld.one/backups.
#
# Design notes captured during planning:
#   - Runs as root (matches rustic/restic convention; needs read on /var/lib
#     /home /root and in some cases /).
#   - Config.json is mutated by the daemon at runtime (modno bumps, guid
#     populated), so it lives at /var/lib/backrest/config.json, not /nix/store.
#     ExecStartPre re-renders it on every start from a Nix-rendered template,
#     with envsubst substituting ${VAR} placeholders for secrets loaded via
#     EnvironmentFile=. Treat the Backrest web UI as read-only; any config
#     change goes through Nix.
#   - Backrest's own auth is disabled; Authelia via Caddy fronts the public
#     backrest-<host>.arsfeld.one subdomain. Firewall opens 9898 on tailscale0
#     only — any tailnet device with a valid Tailscale ACL can reach the
#     daemon directly (that ACL is the out-of-repo trust boundary).
#   - `BACKREST_RESTIC_COMMAND` is hardcoded to nixpkgs restic so Backrest
#     never downloads its own binary into /var/lib.
#   - Uses pkgs-unstable.backrest to track upstream releases faster (both
#     channels ship 1.10.1 today; this decouples from the stable cut cadence).
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
  # one of {cron, maxFrequencyHours, maxFrequencyDays, disabled}.
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

  # Module-level default failure hook. Fires on any error; posts via
  # actionWebhook with an Authorization: Basic header so the ntfy publisher
  # credential stays in EnvironmentFile, never in the rendered config.json.
  defaultFailureHook = {
    conditions = ["CONDITION_ANY_ERROR" "CONDITION_SNAPSHOT_ERROR"];
    actionWebhook = {
      webhookUrl = "https://ntfy.arsfeld.one/backups";
      method = "POST";
      headers = [
        {
          name = "Authorization";
          value = "Basic \${NTFY_BASIC_AUTH_B64}";
        }
        {
          name = "Title";
          value = "Backrest ${cfg.instance}: {{.Repo.Id}}/{{.Plan.Id}} failed";
        }
        {
          name = "Tags";
          value = "floppy_disk,warning";
        }
      ];
      templateBody = "{{.Event}} on {{.Repo.Id}}/{{.Plan.Id}} (host ${cfg.instance}): {{.Error}}";
    };
  };

  renderRepo = name: repo: {
    id = name;
    uri = repo.uri;
    # Password rendered from env by envsubst at ExecStartPre time.
    password = "\${BACKREST_REPO_${strings.toUpper (strings.replaceStrings ["-"] ["_"] name)}_PASSWORD}";
    env = repo.env;
    flags = repo.flags;
    autoUnlock = repo.autoUnlock;
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

  # Full config.json as a Nix attrset → JSON. Placeholders like ${...} pass
  # through builtins.toJSON verbatim and are substituted by envsubst at
  # service start.
  configAttrs = {
    modno = 0;
    version = 4;
    instance = cfg.instance;
    auth = {disabled = true;};
    repos = mapAttrsToList renderRepo cfg.repos;
    plans = mapAttrsToList renderPlan cfg.plans;
  };

  configTemplate = pkgs.writeText "backrest-config.json.tmpl" (builtins.toJSON configAttrs);

  # Environment file list for the systemd unit. Contains per-repo password
  # env exports plus the ntfy publisher credential.
  passwordEnvFile = pkgs.writeShellScript "backrest-password-env-gen" ''
    set -eu
    ${concatStringsSep "\n" (mapAttrsToList (name: repo: let
        envVar = "BACKREST_REPO_${strings.toUpper (strings.replaceStrings ["-"] ["_"] name)}_PASSWORD";
      in ''
        printf '${envVar}=%s\n' "$(cat ${repo.passwordFile})"
      '')
      cfg.repos)}
  '';

  # Per-repo envFiles (rclone creds etc.). Concatenated in systemd's
  # EnvironmentFile= list, which sources them in order.
  repoEnvFiles =
    filter (v: v != null)
    (mapAttrsToList (_: repo: repo.envFile) cfg.repos);

  # Schedule submodule reused on plan.schedule.
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
    # `restic-password` is a shared secret (common.yaml). Individual hosts
    # that need repo-specific passwords can declare additional sops.secrets
    # entries and reference them via repos.<name>.passwordFile.
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

      path = [pkgs.rclone pkgs.openssh pkgs.coreutils pkgs.gettext];

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
        # Password-file contents get read and exported as env vars by the
        # generator script, so systemd can feed them through envsubst.
        EnvironmentFile =
          [config.sops.secrets."ntfy-publisher-env".path]
          ++ repoEnvFiles;
        ExecStartPre = [
          # Generate repo password env lines, then merge with the rendered
          # template. -no-unset and -no-empty make envsubst exit non-zero
          # when a referenced variable is undefined or empty — prevents
          # silent rendering of broken config.json.
          ''${pkgs.writeShellScript "backrest-render-config" ''
              set -euo pipefail
              umask 077
              passwords=$(${passwordEnvFile})
              export $passwords
              ${pkgs.gettext}/bin/envsubst -no-unset -no-empty \
                < ${configTemplate} \
                > /var/lib/backrest/config.json.new
              mv /var/lib/backrest/config.json.new /var/lib/backrest/config.json
            ''}''
        ];
        ExecStart = "${cfg.package}/bin/backrest";
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
