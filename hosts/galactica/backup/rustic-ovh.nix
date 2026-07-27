# galactica's cold backup tier: OVHcloud Cold Archive v2 via rustic.
#
# Replaces the Hetzner Storage Box (~€10.90/mo) with ~€4/mo of tape. Cold
# Archive v2 is an object-level storage class inside an ordinary S3 bucket
# (v1 was bucket-granular and sealed the whole bucket against reads and
# writes, which no incremental repo can survive).
#
# Two buckets, both in eu-west-par — the only region that offers the class:
#   galactica-backup-cold   data packs, written directly as DEEP_ARCHIVE
#   galactica-backup-hot    keys, snapshots, index, tree packs (Standard)
#
# Everything rustic reads for `snapshots`, `ls`, `find` and `check` lives in
# the hot repo, so only real file data ever touches tape.
#
# Cost trap to keep in mind before touching anything here: Cold Archive has a
# 180-day minimum storage duration. Deleting an object early still bills
# (180 - days used) x price. That is why the prune unit passes
# `--keep-pack 180d` — see constellation.rustic's pruneArgs comment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  endpoint = "https://s3.eu-west-par.io.cloud.ovh.net";
  region = "eu-west-par";
  coldBucket = "galactica-backup-cold";
  hotBucket = "galactica-backup-hot";

  # Kept 1:1 with backrest-client.nix's systemExcludes / userExcludes: these
  # two rustic snapshots replace the hetzner-system and hetzner plans exactly.
  # restic's `--exclude <path>` and rustic's `globs = ["!<path>"]` were
  # verified to produce identical file and byte totals on a control tree,
  # including the `/home/*/…` patterns.
  systemExcludes = [
    "/home"
    "/mnt"
    "/dev"
    "/proc"
    "/sys"
    "/run"
    "/tmp"
    "/nix"
    "/var/cache"
    "/var/lib/docker"
    "/var/lib/containers"
    "/var/lib/lxcfs"
    "/var/lib/loki"
    "/var/lib/prometheus2"
  ];

  userExcludes = [
    "/mnt/storage/backups"
    "/mnt/storage/media"
    "/mnt/storage/homes"
    "/mnt/storage/legacy"
    "/home/*/.cache"
    "/home/*/torrents"
  ];

  toGlobs = map (p: "!" + p);

  # rustic substitutes %id with ONE argument holding space-separated pack ids
  # when warm-up-batch > 1 (verified against 0.11.3: a probe script saw
  # ARGC=1 while `echo %id` printed 11 ids on a line). Iterating over the
  # unquoted argument is therefore correct at any batch size, including 1.
  warmUp = pkgs.writeShellScript "rustic-ovh-warm-up" ''
    set -euo pipefail
    export AWS_DEFAULT_REGION=${region}
    export AWS_EC2_METADATA_DISABLED=true
    for id in $1; do
      key="data/''${id:0:2}/$id"
      if ! err=$(${pkgs.awscli2}/bin/aws s3api restore-object \
            --endpoint-url ${endpoint} \
            --bucket ${coldBucket} \
            --key "$key" \
            --restore-request '{"Days":7}' 2>&1); then
        case "$err" in
          *RestoreAlreadyInProgress*) ;;  # another pack in the same run got there first
          *) echo "restore-object failed for $key: $err" >&2; exit 1 ;;
        esac
      fi
    done
  '';

  # Poll rather than guess. `warm-up-wait = "48h"` would make every restore
  # take 48 hours; this makes it take as long as OVH actually takes.
  warmUpWait = pkgs.writeShellScript "rustic-ovh-warm-up-wait" ''
    set -euo pipefail
    export AWS_DEFAULT_REGION=${region}
    export AWS_EC2_METADATA_DISABLED=true
    deadline=$(( $(date +%s) + 172800 ))   # 48 h, OVH's documented ceiling
    for id in $1; do
      key="data/''${id:0:2}/$id"
      while :; do
        json=$(${pkgs.awscli2}/bin/aws s3api head-object \
                 --endpoint-url ${endpoint} --bucket ${coldBucket} --key "$key")
        class=$(${pkgs.jq}/bin/jq -r '.StorageClass // "STANDARD"' <<<"$json")
        restore=$(${pkgs.jq}/bin/jq -r '.Restore // ""' <<<"$json")
        # Not on tape: nothing to wait for. Covers hot-repo packs and any
        # object that predates the DEEP_ARCHIVE default.
        [ "$class" = "DEEP_ARCHIVE" ] || break
        case "$restore" in
          *'ongoing-request="false"'*) break ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "warm-up timed out after 48h waiting for $key" >&2
          exit 1
        fi
        sleep 60
      done
    done
  '';
in {
  # Deliberately NOT the shared restic-password from common.yaml, which
  # basestar, pegasus and raider can all decrypt. A galactica-only key means
  # compromising raider does not also hand over the durable archive.
  sops.secrets."rustic-ovh-password" = {
    mode = "0400";
  };

  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. Consumed twice: rustic expands
  # ${AWS_*} inside the profile (substituteEnv), and awscli2 reads the same
  # names in the warm-up scripts.
  sops.secrets."ovh-s3-env" = {
    mode = "0400";
  };

  constellation.rustic = {
    enable = true;

    profiles.ovh = {
      # Both timers stay null until the seed and the restore drill have
      # passed. Turning them on is a one-line change; see the plan's Task 9.
      timerConfig = null;
      pruneTimerConfig = null;

      # --keep-pack is CLI-only in rustic 0.11.3: there is no [prune] config
      # section and [forget] carries no keep-pack key. It keeps exclusively
      # dead packs on tape for six months so no prune ever trips OVH's
      # 180-day early-deletion penalty.
      pruneArgs = ["--prune" "--keep-pack" "180d"];

      substituteEnv = true;
      environmentFile = config.sops.secrets."ovh-s3-env".path;

      repository = {
        repository = "opendal:s3"; # cold
        repo-hot = "opendal:s3"; # hot
        password-file = config.sops.secrets."rustic-ovh-password".path;
        warm-up-command = "${warmUp} %id";
        warm-up-wait-command = "${warmUpWait} %id";
        warm-up-batch = 1;

        options-cold = {
          bucket = coldBucket;
          endpoint = endpoint;
          region = region;
          # The whole design hangs on this string. opendal ignores unknown
          # option keys silently, so a typo here would write terabytes at the
          # Standard rate with no error anywhere — head-object a data pack
          # after the first real backup and confirm the class.
          default_storage_class = "DEEP_ARCHIVE";
          access_key_id = "\${AWS_ACCESS_KEY_ID}";
          secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
        };

        options-hot = {
          bucket = hotBucket;
          endpoint = endpoint;
          region = region;
          access_key_id = "\${AWS_ACCESS_KEY_ID}";
          secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
        };
      };

      # Replaces the hetzner-system and hetzner Backrest plans respectively.
      # `label` is part of rustic's default group-by (host,label,paths), so
      # the two sets retain independently.
      backup.snapshots = [
        {
          sources = ["/"];
          globs = toGlobs systemExcludes;
          label = "system";
        }
        {
          sources = ["/home" "/mnt/storage"];
          globs = toGlobs userExcludes;
          label = "user";
        }
      ];

      # Matches remoteRetention in backrest-client.nix. `prune` is left unset
      # (defaults false) — the backup unit never forgets, and the prune unit
      # passes --prune on the command line.
      forget = {
        keep-daily = 7;
        keep-weekly = 4;
        keep-monthly = 6;
      };
    };
  };
}
