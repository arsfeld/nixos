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

  # Prune and check are repo-scoped in Backrest, and an ABSENT policy means
  # "never": taskprune.go / taskcheck.go both return NeverScheduledTask when
  # <Policy>.GetSchedule() is nil. That is how every repo in this fleet went
  # unpruned and unchecked from the start. Both therefore default to a monthly
  # schedule, so a repo added later is covered without anyone remembering to
  # opt in; set the option to null to disable deliberately.
  prunePolicyType = types.submodule {
    options = {
      schedule = mkOption {
        type = scheduleType;
        default = {maxFrequencyDays = 30;};
        description = "When to prune. Same Schedule shape as plan schedules.";
      };
      maxUnusedPercent = mkOption {
        type = types.number;
        default = 10;
        description = ''
          Unused space restic may leave behind, as a percentage. NEVER set this
          to 0: Backrest renders it straight into `--max-unused <n>%`, and 0%
          forces a full repack on every prune. Backrest's own 25% fallback
          applies only when the whole policy is absent, which it never is once
          this module emits one.
        '';
      };
      maxUnusedBytes = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Absolute byte budget. Takes precedence over maxUnusedPercent when set.";
      };
    };
  };

  checkPolicyType = types.submodule {
    options = {
      schedule = mkOption {
        type = scheduleType;
        default = {maxFrequencyDays = 30;};
        description = "When to check. Same Schedule shape as plan schedules.";
      };
      readDataSubsetPercent = mkOption {
        type = types.nullOr types.number;
        default = null;
        description = ''
          Percentage of pack data to re-read. null means structure-only, which
          verifies index/snapshot/tree consistency without downloading packs.
          Leave it null for every remote repo — reading data costs egress.
        '';
      };
    };
  };

  renderPrunePolicy = p:
    {schedule = renderSchedule p.schedule;}
    // (
      if p.maxUnusedBytes != null
      then {maxUnusedBytes = p.maxUnusedBytes;}
      else {maxUnusedPercent = p.maxUnusedPercent;}
    );

  # CheckPolicy models its two modes as a proto oneof, so exactly one arm must
  # be set — structureOnly is not an implicit default.
  renderCheckPolicy = c:
    {schedule = renderSchedule c.schedule;}
    // (
      if c.readDataSubsetPercent != null
      then {readDataSubsetPercent = c.readDataSubsetPercent;}
      else {structureOnly = true;}
    );

  # One failure hook, attached to the REPO rather than to plans.
  #
  # NotifyError prepends CONDITION_ANY_ERROR to every error path
  # (tasks/errors.go), and the explicit ExecuteHooks calls in taskbackup.go,
  # taskprune.go and taskcheck.go include it too — so this single condition
  # covers backup, forget, prune, check and index failures.
  #
  # It lives on the repo and NOT also on plans because TasksTriggeredByEvent
  # iterates repo.GetHooks() AND plan.GetHooks(). A plan-level copy matching the
  # same condition would send a second ntfy message for every failure. Repo
  # level also covers repos that have no plans at all, which is the only place
  # prune and check errors on galactica's `storage` entry could ever surface.
  #
  # {{.Plan.Id}} is safe here: when a task has no plan, Backrest substitutes a
  # placeholder Plan carrying only the ID (taskrunnerimpl.go), so this renders
  # the real plan for backup failures and an empty string for repo-scoped prune
  # and check failures. It does not error.
  #
  # The POST itself lives in constellation.backupNotify so rustic's units share
  # exactly one implementation. Backrest cannot use the templated
  # backup-notify@.service — it needs Backrest's own {{...}} expansion, which
  # only happens inside an actionCommand.
  defaultFailureHook = {
    conditions = ["CONDITION_ANY_ERROR"];
    actionCommand = {
      command = ''
        #!${pkgs.bash}/bin/bash
        ${config.constellation.backupNotify.script} \
          'Backrest ${cfg.instance}: {{.Repo.Id}}/{{.Plan.Id}} failed' \
          '{{.Event}} on {{.Repo.Id}}/{{.Plan.Id}} (host ${cfg.instance}): {{.Error}}'
      '';
    };
  };

  renderRepo = name: repo:
    {
      id = name;
      uri = repo.uri;
      password = ""; # restic reads from RESTIC_PASSWORD_FILE via env below
      env =
        ["RESTIC_PASSWORD_FILE=${toString repo.passwordFile}"]
        ++ repo.env;
      flags = repo.flags;
      autoUnlock = repo.autoUnlock;
      hooks =
        if repo.hooks == null
        then [defaultFailureHook]
        else repo.hooks;
      # autoInitialize is set by the merge script for repos that have no guid
      # yet (new repos). Once a guid is present autoInitialize must be absent —
      # Backrest rejects configs that set both.
    }
    // optionalAttrs (repo.prune != null) {prunePolicy = renderPrunePolicy repo.prune;}
    // optionalAttrs (repo.check != null) {checkPolicy = renderCheckPolicy repo.check;};

  # A standalone restic invocation per repo, carrying the same credentials the
  # daemon gives restic. rclone-backed repos need rclone on PATH; without it
  # they report an error rather than silently reading as healthy.
  #
  # Wrapped in `timeout` so an unreachable repo (e.g. a rest: endpoint on a
  # host that's offline) fails fast instead of hanging until TCP gives up —
  # backup-status runs over ssh as part of an unattended sweep and one dead
  # repo must not stall the whole report.
  resticQuery = name: repo:
    pkgs.writeShellScript "backup-status-restic-${name}" ''
      set -euo pipefail
      export PATH=${makeBinPath [pkgs.rclone pkgs.openssh]}:$PATH
      export RESTIC_PASSWORD_FILE=${toString repo.passwordFile}
      ${optionalString (repo.envFile != null) ''
        set -a
        . ${toString repo.envFile}
        set +a
      ''}
      ${concatMapStrings (e: "export ${e}\n") repo.env}
      exec ${pkgs.coreutils}/bin/timeout 120 ${pkgs.restic}/bin/restic -r ${escapeShellArg repo.uri} snapshots --json
    '';

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
      then [] # the default failure hook is repo-level; see defaultFailureHook
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
    DEST=${cfg.dataDir}/config.json
    LIVE=$([ -f "$DEST" ] && cat "$DEST" || echo '{}')
    echo "$LIVE" | ${pkgs.jq}/bin/jq -s '
      .[0] as $tpl | .[1] as $live |
      $tpl
      | .modno = ($live.modno // 0)
      | .repos = (.repos | map(
          . as $r |
          ($live.repos // [] | map(select(.id == $r.id)) | first) as $lr |
          if $lr.guid
          then . + {guid: $lr.guid}
          else . + {autoInitialize: true}
          end
        ))
      | if $live.sync then . + {sync: $live.sync} else . end
    ' ${configTemplate} - > "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
    chmod 0600 "$DEST"
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
      prune = mkOption {
        type = types.nullOr prunePolicyType;
        default = {};
        description = "Prune policy for this repo. null disables pruning entirely.";
      };
      check = mkOption {
        type = types.nullOr checkPolicyType;
        default = {};
        description = "Integrity check policy for this repo. null disables checks entirely.";
      };
      hooks = mkOption {
        type = types.nullOr (types.listOf types.attrs);
        default = null;
        description = "Repo hooks. null = module default failure hook. [] = no hooks.";
      };
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Snapshot age above which backup-status reports this repo stale.
          Must exceed the interval of the plans writing to it.
        '';
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
        description = "Per-plan hooks. null = none (the default failure hook is repo-level). [] = no hooks.";
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
      description = "Open 9898 on tailscale0 so galactica's Caddy can proxy the UI.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/backrest";
      description = "Directory where Backrest stores its config and state.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/backrest";
      description = "Directory used by restic for its cache.";
    };

    ntfyUrl = mkOption {
      type = types.str;
      default = "https://ntfy.arsfeld.one/backups";
      description = "ntfy topic URL for backup failure notifications.";
    };

    ntfyPublisherEnvFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "EnvironmentFile providing NTFY_BASIC_AUTH_B64 for the failure hook. Defaults to the sops ntfy-publisher-env secret.";
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

    constellation.backupNotify.enable = mkDefault true;
    constellation.backupStatus.enable = mkDefault true;
    constellation.backupStatus.sources =
      mapAttrsToList (name: repo: {
        inherit name;
        kind = "restic";
        command = toString (resticQuery name repo);
        inherit (repo) maxAgeHours;
      })
      cfg.repos;

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
        BACKREST_DATA = cfg.dataDir;
        BACKREST_CONFIG = "${cfg.dataDir}/config.json";
        BACKREST_PORT = cfg.bindAddress;
        BACKREST_RESTIC_COMMAND = "${pkgs.restic}/bin/restic";
        XDG_CACHE_HOME = cfg.cacheDir;
      };

      serviceConfig = let
        ntfyEnvFile =
          if cfg.ntfyPublisherEnvFile != null
          then cfg.ntfyPublisherEnvFile
          else config.sops.secrets."ntfy-publisher-env".path;
      in {
        Type = "simple";
        StateDirectory = lib.removePrefix "/var/lib/" cfg.dataDir;
        StateDirectoryMode = "0700";
        CacheDirectory = lib.removePrefix "/var/cache/" cfg.cacheDir;
        CacheDirectoryMode = "0700";
        # ntfy-publisher-env provides NTFY_BASIC_AUTH_B64 for the failure hook.
        # Per-repo envFiles (e.g. hetzner-webdav-env) flow through to restic
        # via env inheritance.
        EnvironmentFile =
          [ntfyEnvFile]
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
