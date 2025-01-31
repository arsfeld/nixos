{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rustic;

  globalOptions = { ... }: {
  options = {
    useProfiles = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of profiles to use";
    };

    logLevel = mkOption {
      type = types.enum [ "off" "error" "warn" "info" "debug" "trace" ];
      default = "info";
      description = "Log level for rustic";
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to the log file";
    };

    noProgress = mkOption {
      type = types.bool;
      default = false;
      description = "Disable progress reporting";
    };

    progressInterval = mkOption {
      type = types.str;
      default = "100ms";
      description = "Progress reporting interval";
    };

    dryRun = mkOption {
      type = types.bool;
      default = false;
      description = "Perform a dry run without making any changes";
    };

    checkIndex = mkOption {
      type = types.bool;
      default = false;
      description = "Check index before backup";
    };

    hooks = mkOption {
      type = types.submodule {
        options = {
          runBefore = mkOption {
            type = types.listOf (types.either types.str (types.submodule {
              options = {
                command = mkOption { type = types.str; };
                args = mkOption { type = types.listOf types.str; };
                onFailure = mkOption {
                  type = types.enum [ "error" "warn" "ignore" ];
                  default = "error";
                };
              };
            }));
            default = [];
            description = "Commands to run before each rustic command";
          };
          runAfter = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Commands to run after successful rustic command";
          };
          runFailed = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Commands to run after failed rustic command";
          };
          runFinally = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Commands to always run after rustic command";
          };
        };
      };
      default = {};
      description = "Global hooks for rustic commands";
    };

    env = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Global environment variables for rustic commands";
    };
  };

  snapshotsOptions = { ... }: {
    options = {
      sources = mkOption {
        type = types.listOf types.str;
        description = "Paths to back up";
      };

      globs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of glob patterns to exclude from this source (case-sensitive)";
      };

      iglobs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of glob patterns to exclude from this source (case-insensitive)";
      };

      label = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Label for this backup source";
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of tags for this backup source";
      };

      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Description for this backup source";
      };

      extraOptions = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        description = "Additional options for this specific source";
      };
    };
  };

  repositoryOptions = { name, config, ... }: {
    options = {
      enable = mkEnableOption "Rustic backup for ${name}";

      repository = mkOption {
        type = types.str;
        description = "Repository URL or path";
      };

      hotRepository = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Hot repository URL or path (optional)";
      };

      passwordFile = mkOption {
        type = types.str;
        description = "Path to the file containing the repository password";
      };

      snapshots = mkOption {
        type = types.listOf (types.submodule snapshotsOptions);
        default = [];
        description = "List of snapshots to back up";
      };

      backupOptions = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        description = "Global backup options applied to all snapshots";
      };

      globs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of global glob patterns to exclude from backup (case-sensitive)";
      };

      iglobs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of global glob patterns to exclude from backup (case-insensitive)";
      };

      noCache = mkOption {
        type = types.bool;
        default = false;
        description = "Disable caching";
      };

      cacheDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Custom cache directory";
      };

      warmUp = mkOption {
        type = types.bool;
        default = false;
        description = "Warm up repository by file access";
      };

      warmUpCommand = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Command to warm up repository";
      };

      warmUpWait = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Wait time for warm-up";
      };

      extraOptions = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        description = "Additional options to pass to Rustic";
      };

      timerConfig = mkOption {
        type = types.attrsOf types.str;
        default = {
          OnCalendar = "daily";
          RandomizedDelaySec = "1h";
        };
        description = "Systemd timer configuration for automated backups";
      };
    };
  };

  generateRusticConfig = name: cfg:
    let
      configData = {
        global = {
          use-profiles = cfg.useProfiles;
          log-level = cfg.logLevel;
          log-file = cfg.logFile;
          no-progress = cfg.noProgress;
          progress-interval = cfg.progressInterval;
          dry-run = cfg.dryRun;
          check-index = cfg.checkIndex;
          hooks = cfg.hooks;
          env = cfg.env;
        };
        repository = {
          repository = cfg.repository;
          password-file = cfg.passwordFile;
          no-cache = cfg.noCache;
          cache-dir = cfg.cacheDir;
          warm-up = cfg.warmUp;
          warm-up-command = cfg.warmUpCommand;
          warm-up-wait = cfg.warmUpWait;
        } // (if cfg.hotRepository != null then { repo-hot = cfg.hotRepository; } else {});
        backup = cfg.backupOptions // {
          snapshots = map (source: {
            sources = source.sources;
          } // (if source.globs != [] then { globs = source.globs; } else {})
            // (if source.iglobs != [] then { iglobs = source.iglobs; } else {})
            // source.extraOptions
          ) cfg.sources;
        } // (if cfg.globs != [] then { globs = cfg.globs; } else {})
          // (if cfg.iglobs != [] then { iglobs = cfg.iglobs; } else {});
      } // cfg.extraOptions;

      format = pkgs.formats.toml {};
    in
    format.generate "rustic-${name}.toml" configData;

  wrapRusticCommand = name: repoCfg:
    let
      configFile = generateRusticConfig name repoCfg;
    in
    pkgs.writeShellScriptBin "rustic-${name}" ''
      exec ${pkgs.rustic}/bin/rustic --config ${configFile} "$@"
    '';

in {
  options.services.rustic = {
    repositories = mkOption {
      type = types.attrsOf (types.submodule repositoryOptions);
      default = {};
      description = "Rustic backup repositories configuration";
    };
  };

  config = mkIf (cfg.repositories != {}) {
    environment.systemPackages = [ pkgs.rustic ] ++ 
      (mapAttrsToList wrapRusticCommand cfg.repositories);

    systemd.services = mapAttrs' (name: repoCfg:
      nameValuePair "rustic-${name}" {
        description = "Rustic backup for ${name}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.rustic}/bin/rustic --config ${generateRusticConfig name repoCfg} backup";
        };
      }
    ) cfg.repositories;

    systemd.timers = mapAttrs' (name: repoCfg:
      nameValuePair "rustic-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = repoCfg.timerConfig;
      }
    ) cfg.repositories;
  };
}