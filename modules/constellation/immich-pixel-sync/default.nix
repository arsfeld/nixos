# Immich → Pixel photo staging
#
# Builds a flat staging directory that is a pure function of one Immich query:
# every asset owned by `ownerId` whose `fileCreatedAt` falls inside a rolling
# window. Apple Live Photo pairs are muxed into Google Motion Photos so they
# arrive in Google Photos as a single item; everything else is hardlinked.
#
# The staging directory is the interface. This module knows nothing about
# Syncthing — declare the folder wherever Syncthing is configured (on galactica
# that is hosts/galactica/services/files.nix).
#
# Nothing here ever writes into Immich's library. Everything staged is a reflink
# copy — free on btrfs, but a separate inode, which matters: Immich's originals
# are mode 0600 and Syncthing runs as another user, so staged files must be
# group-readable. A hardlink would share the original's inode and chmod-ing it
# would relax Immich's own permissions.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.immichPixelSync;

  # Sibling of the staging directory, so reflink copies and the final rename stay
  # on one filesystem while staying outside the tree Syncthing exports.
  tmpDirectory = "${cfg.stagingDirectory}.tmp";
  stateDirectory = "/var/lib/immich-pixel-sync";

  immichPixelSync = pkgs.writeShellApplication {
    name = "immich-pixel-sync";
    runtimeInputs = [pkgs.coreutils pkgs.exiftool cfg.database.package];
    text = ''
      export IPS_STAGING_DIR=${escapeShellArg cfg.stagingDirectory}
      export IPS_TMP_DIR=${escapeShellArg tmpDirectory}
      export IPS_LOCK_FILE=${escapeShellArg "${stateDirectory}/lock"}
      export IPS_OWNER_ID=${escapeShellArg cfg.ownerId}
      export IPS_WINDOW_DAYS=${toString cfg.windowDays}
      export IPS_SHRINK_GUARD_PERCENT=${toString cfg.shrinkGuardPercent}
      export IPS_NOT_BEFORE=${escapeShellArg (
        if cfg.notBefore == null
        then "1970-01-01"
        else cfg.notBefore
      )}
      export IPS_DB_NAME=${escapeShellArg cfg.database.name}
      export IPS_DB_USER=${escapeShellArg cfg.database.user}
      export IPS_DB_SOCKET=${escapeShellArg cfg.database.socketDirectory}
      exec ${pkgs.python3}/bin/python3 ${./sync.py} "$@"
    '';
  };
in {
  options.constellation.immichPixelSync = {
    enable = mkEnableOption "staging recent Immich assets for a Pixel via Syncthing";

    ownerId = mkOption {
      type = types.str;
      example = "c85fe467-a36a-457a-a260-a67dfe2199da";
      description = ''
        Immich `asset."ownerId"` UUID whose assets are staged. Only this user's
        assets are ever copied; every other user's stay where they are.

        This is the account UUID, not the storage label — Immich names the
        on-disk directory from the OIDC `preferred_username` claim, which can
        change without warning. Paths are always read from the database.
      '';
    };

    stagingDirectory = mkOption {
      type = types.path;
      default = "/mnt/storage/files/PixelPhotoStage";
      description = ''
        Flat directory holding the staged assets. Must be on the same filesystem
        as Immich's library so hardlinks and reflinks work. Export this with
        Syncthing as a `sendonly` folder.
      '';
    };

    windowDays = mkOption {
      type = types.ints.positive;
      default = 30;
      description = ''
        Rolling window, in days, over `fileCreatedAt`. Assets that fall out of it
        are deleted from the staging directory — and therefore from the Pixel —
        on the next run. The phone is a buffer, not an archive.
      '';
    };

    shrinkGuardPercent = mkOption {
      type = types.ints.between 0 100;
      default = 50;
      description = ''
        Abort the run if it would shrink the staged set by more than this
        percentage, rather than mass-deleting off the phone. Skipped when the
        staging directory is empty, so first runs are never blocked. Override a
        single run with `immich-pixel-sync --force`.
      '';
    };

    notBefore = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "2026-07-26T23:00:00-04:00";
      description = ''
        Never stage an asset whose `fileCreatedAt` is older than this, whatever
        `windowDays` says. Any value PostgreSQL accepts as a `timestamptz`.

        Google Photos deduplicates on file content, and muxing a Live Photo
        deliberately changes its bytes, so a photo it already holds from some
        earlier sync path arrives as a *second* copy instead of being recognised.
        Set this to the moment this module took over so the rolling window can
        never reach back into already-uploaded history.

        Once `windowDays` has elapsed past the cutover the floor stops having any
        effect, and it can be left in place.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "hourly";
      description = "systemd `OnCalendar` expression for the staging timer.";
    };

    user = mkOption {
      type = types.str;
      default = "media";
      description = ''
        User to run as. Must be able to read Immich's library files, and must map
        to the Immich database role in PostgreSQL's ident map.

        Staged files are written mode 0640 owned by this user, so whichever user
        Syncthing runs as needs to share this group — Immich's own originals are
        0600 and are never modified.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group to run as.";
    };

    database = {
      name = mkOption {
        type = types.str;
        default = "immich";
        description = "Immich database name.";
      };

      user = mkOption {
        type = types.str;
        default = "immich";
        description = "PostgreSQL role to connect as, via peer auth over the socket.";
      };

      socketDirectory = mkOption {
        type = types.path;
        default = "/run/postgresql";
        description = "PostgreSQL unix socket directory.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = literalExpression "pkgs.postgresql";
        description = "Package providing the `psql` client.";
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [immichPixelSync];

    systemd.tmpfiles.rules = [
      "d ${cfg.stagingDirectory} 0775 ${cfg.user} ${cfg.group} -"
      "d ${tmpDirectory} 0775 ${cfg.user} ${cfg.group} -"
      "d ${stateDirectory} 0755 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.immich-pixel-sync = {
      description = "Stage recent Immich assets for the Pixel";
      after = ["postgresql.service" "mnt-storage.mount"];
      requires = ["postgresql.service" "mnt-storage.mount"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${immichPixelSync}/bin/immich-pixel-sync";
        User = cfg.user;
        Group = cfg.group;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.immich-pixel-sync = {
      description = "Immich → Pixel staging timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
