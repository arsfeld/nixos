# Constellation rustic module
#
# Resurrected from modules/rustic.nix, retired in 362b751 ("refactor(modules):
# retire rustic and refresh backup docs"), and reshaped to constellation
# conventions.
#
# rustic exists *alongside* Backrest, not instead of it. Backrest wraps restic,
# and restic has no hot/cold repository concept, so a cold-storage tier (OVH
# Cold Archive, i.e. tape) cannot live inside Backrest:
#
#   Backrest owns the warm tiers (local NAS, pegasus REST).
#   rustic   owns the cold tier  (OVH).
#
# They never touch the same repo.
#
# Five deliberate changes from the retired version:
#   - Prune is a separate unit on its own timer. The old module only ran
#     `backup`. Pruning a cold repo weekly is wrong; it is monthly here.
#   - IOSchedulingClass = "idle", restoring the per-plan ionice that the
#     Backrest migration had to drop (see backrest-client.nix:11-15). rustic
#     gets its own unit, so it is free to reinstate it.
#   - OnFailure into the shared ntfy path. The retired module had no failure
#     reporting at all.
#   - No repo password of its own is assumed: the profile supplies
#     password-file, so a host can scope its archive password separately from
#     the fleet-wide restic-password in common.yaml.
#   - No `init` in ExecStartPre. The old module ran it before every backup with
#     a `-` prefix, so a misconfigured repo would be silently created rather
#     than reported. Init once, by hand.
#
# Each profile generates:
#   /etc/rustic/<name>.toml         rendered from the freeform attrs
#   rustic-<name>.service           backup, oneshot
#   rustic-<name>.timer             iff timerConfig != null
#   rustic-<name>-prune.service     forget + prune, oneshot
#   rustic-<name>-prune.timer       iff pruneTimerConfig != null
#   rustic-<name>-check.service     structure-only check, oneshot
#   rustic-<name>-check.timer       iff checkTimerConfig != null
#   rustic-<name>                   wrapper on PATH for manual invocation
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib; let
  cfg = config.constellation.rustic;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };

  tomlFormat = pkgs.formats.toml {};

  # Attributes this module consumes rather than passing through to the TOML.
  # rustic rejects nothing and opendal silently ignores unknown option keys,
  # so anything left in here by accident would be invisible, not an error.
  moduleKeys = [
    "timerConfig"
    "pruneTimerConfig"
    "checkTimerConfig"
    "pruneArgs"
    "environment"
    "environmentFile"
    "substituteEnv"
    "maxAgeHours"
  ];

  profileToml = name: profile:
    tomlFormat.generate "rustic-${name}.toml" (
      recursiveUpdate
      {global.log-file = "${cfg.logDir}/${name}.log";}
      (removeAttrs profile moduleKeys)
    );

  profileEnv = profile:
    {
      RUSTIC_CACHE_DIR = cfg.cacheDir;
    }
    // optionalAttrs profile.substituteEnv {
      RUSTIC_PROFILE_SUBSTITUTE_ENV = "true";
    }
    // optionalAttrs (profile.environment != null) profile.environment;

  # Nice + idle I/O so a multi-hour upload never competes with the media
  # services this host exists to run.
  hardening = {
    Nice = 10;
    IOSchedulingClass = "idle";
  };

  backupServices = mapAttrs' (name: profile:
    nameValuePair "rustic-${name}" {
      description = "rustic backup (profile ${name})";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = profileEnv profile;
      onFailure = ["backup-notify@rustic-${name}.service"];
      serviceConfig =
        hardening
        // {
          Type = "oneshot";
          # No auto-init, unlike the retired module. `rustic init` against a
          # repo that merely *looks* empty — wrong bucket name, wrong
          # credentials scope — would silently create a second, fresh repo
          # and every backup after that would report success into the void.
          # Initialisation is a one-time deliberate act: `sudo rustic-<name> init`.
          ExecStart = "${cfg.package}/bin/rustic -P ${name} backup";
          EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
        };
    })
  cfg.profiles;

  pruneServices = mapAttrs' (name: profile:
    nameValuePair "rustic-${name}-prune" {
      description = "rustic forget + prune (profile ${name})";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = profileEnv profile;
      onFailure = ["backup-notify@rustic-${name}-prune.service"];
      serviceConfig =
        hardening
        // {
          Type = "oneshot";
          # PRUNE OPTIONS are CLI-only: rustic 0.11.3 has no [prune] config
          # section and [forget] carries no keep-pack key, so --keep-pack
          # cannot move into the profile. Losing it silently means paying
          # OVH's early-deletion penalty (180-day minimum) on every prune.
          ExecStart = concatStringsSep " " (
            ["${cfg.package}/bin/rustic" "-P" name "forget"] ++ profile.pruneArgs
          );
          EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
        };
    })
  cfg.profiles;

  # Structure-only, deliberately. `rustic check` reads pack CONTENTS only under
  # --read-data (rustic_core's check.rs gates it, and --read-data-subset is
  # declared requires="read_data"). Without that flag it does list_with_size
  # against both backends and reads snapshots, index and tree packs from the
  # HOT repo — so on a hot/cold repository nothing is retrieved from tape, and
  # it still catches a pack the index references but the cold bucket lacks.
  #
  # --read-data is not exposed as an option on purpose. Against OVH Cold
  # Archive every pack would go through restore-object with warm-up-batch = 1
  # and a poll that waits up to 48h PER PACK, plus retrieval billing and 7-day
  # restore copies. There is no schedule on which that is acceptable.
  checkServices = mapAttrs' (name: profile:
    nameValuePair "rustic-${name}-check" {
      description = "rustic check (profile ${name})";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = profileEnv profile;
      onFailure = ["backup-notify@rustic-${name}-check.service"];
      serviceConfig =
        hardening
        // {
          Type = "oneshot";
          ExecStart = "${cfg.package}/bin/rustic -P ${name} check";
          EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
        };
    })
  cfg.profiles;

  mkTimer = suffix: field:
    mapAttrs' (name: profile:
      nameValuePair "rustic-${name}${suffix}" {
        description = "Timer for rustic-${name}${suffix}";
        wantedBy = ["timers.target"];
        timerConfig = profile.${field};
      })
    (filterAttrs (_: p: p.${field} != null) cfg.profiles);

  mkProfileScript = name: profile:
    pkgs.writeShellScriptBin "rustic-${name}" ''
      set -euo pipefail
      export RUSTIC_CACHE_DIR=${cfg.cacheDir}
      ${optionalString profile.substituteEnv "export RUSTIC_PROFILE_SUBSTITUTE_ENV=true"}
      ${optionalString (profile.environmentFile != null) ''
        set -a
        . ${profile.environmentFile}
        set +a
      ''}
      ${concatStrings (mapAttrsToList (k: v: "export ${k}=${escapeShellArg v}\n")
        (
          if profile.environment == null
          then {}
          else profile.environment
        ))}
      exec ${cfg.package}/bin/rustic -P ${name} "$@"
    '';

  profileScripts = mapAttrsToList mkProfileScript cfg.profiles;

  profileType = types.submodule {
    freeformType = types.attrs;
    options = {
      timerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the backup unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "Sun *-*-* 04:30:00";}'';
      };
      pruneTimerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the forget+prune unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "*-*-01 03:00:00";}'';
      };
      checkTimerConfig = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "systemd timer for the check unit. null means manual-only.";
        example = literalExpression ''{OnCalendar = "*-*-06 09:00:00";}'';
      };
      pruneArgs = mkOption {
        type = types.listOf types.str;
        default = ["--prune"];
        description = ''
          Arguments appended to `rustic -P <name> forget`. Retention comes from
          the profile's [forget] table; only CLI-only prune options belong here.
        '';
        example = literalExpression ''["--prune" "--keep-pack" "180d"]'';
      };
      environment = mkOption {
        type = types.nullOr (types.attrsOf types.str);
        default = null;
        description = "Extra environment for this profile's units. Never secrets.";
      };
      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "EnvironmentFile for this profile's units (S3 credentials etc.).";
        example = "/run/secrets/ovh-s3-env";
      };
      substituteEnv = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Pass RUSTIC_PROFILE_SUBSTITUTE_ENV=true, making rustic expand $VAR and
          ''${VAR} inside the profile. Required to keep credentials out of the
          Nix store. Note it applies to the whole profile — a literal `$` in any
          value (a glob, a path) would be substituted too.
        '';
      };
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Snapshot age above which backup-status reports this profile stale.
          Must exceed the profile's own timerConfig interval.
        '';
      };
    };
  };
in {
  options.constellation.rustic = {
    enable = mkEnableOption "rustic backup profiles (cold-storage tier)";

    package = mkOption {
      type = types.package;
      default = pkgs-unstable.rustic;
      description = ''
        rustic package. Defaults to pkgs-unstable: stable is 0.11.2, and the
        cold-storage design was verified against 0.11.3.
      '';
    };

    logDir = mkOption {
      type = types.str;
      default = "/var/log/rustic";
      description = "Directory for per-profile rustic log files.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/rustic";
      description = "Shared rustic cache directory.";
    };

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = {};
      description = ''
        Attribute set of rustic profiles. Every attribute other than
        timerConfig, pruneTimerConfig, pruneArgs, environment, environmentFile
        and substituteEnv is written verbatim into /etc/rustic/<name>.toml.
      '';
    };
  };

  config = mkIf cfg.enable {
    constellation.backupNotify.enable = mkDefault true;
    constellation.backupStatus.enable = mkDefault true;
    constellation.backupStatus.sources =
      mapAttrsToList (name: profile: {
        inherit name;
        kind = "rustic";
        # rustic prints its [INFO] banner to stderr, so stdout is clean JSON.
        command = "${mkProfileScript name profile}/bin/rustic-${name} snapshots --json";
        inherit (profile) maxAgeHours;
      })
      cfg.profiles;

    environment.systemPackages = [cfg.package] ++ profileScripts;

    environment.etc = mapAttrs' (name: profile:
      nameValuePair "rustic/${name}.toml" {source = profileToml name profile;})
    cfg.profiles;

    systemd.services = backupServices // pruneServices // checkServices;
    systemd.timers =
      (mkTimer "" "timerConfig")
      // (mkTimer "-prune" "pruneTimerConfig")
      // (mkTimer "-check" "checkTimerConfig");

    systemd.tmpfiles.rules = [
      "d ${cfg.logDir} 0750 root root -"
      "d ${cfg.cacheDir} 0750 root root -"
    ];
  };
}
