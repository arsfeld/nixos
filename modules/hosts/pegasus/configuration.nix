{
  configurations.nixos.pegasus.module = {
    lib,
    pkgs,
    config,
    ...
  }: {
    # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
    # publishes). owner + mode let the user-mode script read it directly.
    sops.secrets."ntfy-publisher-env" = {
      sopsFile = ../../../secrets/sops/ntfy-client.yaml;
      owner = "arosenfeld";
      mode = "0400";
    };

    # The media containers mount mediaVolumes (/media + /files). galactica has a
    # /mnt/storage/files share; pegasus does not, and podman refuses to bind-mount
    # a missing source. Create an empty one so Plex/Stash/mydia can start.
    #
    # Also ensure the media library dirs exist with the media (5000) owner: with
    # mediaSync is disabled (see below), nothing else creates them, and mydia/
    # Transmission import completed Movies/Series into them.
    systemd.tmpfiles.rules = [
      "d /mnt/storage/files 0775 media media -"
      "d /mnt/storage/media 0775 media media -"
      "d /mnt/storage/media/Movies 0775 media media -"
      "d /mnt/storage/media/Series 0775 media media -"
      "d /mnt/storage/media/Vault 0775 media media -"
      "d /mnt/storage/media/Downloads 0775 media media -"
    ];

    # nofail is deliberate: pegasus must boot without the data pool.
    # Services that need the pool gate themselves via RequiresMountsFor.
    #
    # mount-timeout=2min: the spinning SATA drives behind the LSI/mpt2sas HBA can
    # be slow to settle at boot; a device reset mid-mount once interrupted the
    # btrfs mount (open_ctree -4) within ~7s, stranding it. Give the mount room to
    # finish. nofail drops the before-local-fs.target ordering, so a slow mount
    # never blocks boot. storage-mount-watchdog (below) retries if it still fails.
    fileSystems."/mnt/storage" = {
      device = "/dev/disk/by-uuid/01cdd316-d539-42a4-b87c-de5d14d40c94";
      fsType = "btrfs";
      options = [
        "compress=zstd"
        "noatime"
        "nofail"
        "x-systemd.device-timeout=30s"
        "x-systemd.mount-timeout=2min"
      ];
    };

    # Self-heal for the data pool. systemd never retries a failed .mount unit, and
    # a mount that fails at boot cancels every service that Requires= it; a later
    # manual remount does NOT re-pull them from multi-user.target. So if the boot
    # mount is interrupted, plex/stash/mydia/transmission stay dead until someone
    # notices. This watchdog closes that gap: it retries the mount and (re)starts
    # the storage-dependent containers once the pool is back.
    #
    # The dependent list is derived from the media containers that mount the pool
    # (mediaVolumes) plus transmission, which bind-mounts /mnt/storage/media by
    # hand (see services/transmission.nix). Note: this also restarts a service you
    # stopped by hand within ~2min — acceptable for an always-on media box.
    systemd.services.storage-mount-watchdog = let
      storageUnits = lib.unique (
        (map (n: "podman-${n}.service")
          (lib.attrNames (lib.filterAttrs (_: c: c.enable && c.mediaVolumes) config.media.containers)))
        ++ ["podman-transmission.service"]
      );
      systemctl = "${config.systemd.package}/bin/systemctl";
      mountpoint = "${pkgs.util-linux}/bin/mountpoint";
    in {
      description = "Ensure /mnt/storage is mounted and storage-dependent services are running";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        if ! ${mountpoint} -q /mnt/storage; then
          echo "/mnt/storage not mounted; attempting mnt-storage.mount" >&2
          ${systemctl} start mnt-storage.mount || true
        fi
        if ${mountpoint} -q /mnt/storage; then
          for unit in ${lib.concatStringsSep " " storageUnits}; do
            ${systemctl} reset-failed "$unit" 2>/dev/null || true
            ${systemctl} start "$unit" || true
          done
        fi
      '';
    };

    systemd.timers.storage-mount-watchdog = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "2min";
      };
    };

    # mediaSync stays DISABLED until its cleanup is fixed.
    #
    # Cleanup deletes any unmarked *directory* under /mnt/storage/media, and
    # when galactica is unreachable the remote marker scan fails, so the "keep"
    # set is empty and a nightly run would wipe every synced directory. Before
    # re-enabling: make cleanup a no-op when the scan fails, and re-mark (or
    # relocate) the Vault subdirectories the one-off rsync created during the
    # galactica move, or the first managed run deletes them.
    constellation.mediaSync.enable = false;

    # Media stack with pegasus's own public domain (arsfeld.xyz), served over a
    # Cloudflare tunnel (modules/hosts/pegasus/services/cloudflared.nix). This makes Plex,
    # Stash and mydia reachable without Tailscale while galactica is offline.
    # galactica hosts Authelia/OIDC, so every service here sets bypassAuth and
    # relies on its own login (see services/media.nix).
    media.config = {
      enable = true;
      domain = "arsfeld.xyz";
    };
    media.gateway.enable = true;

    # Caddy terminates TLS for *.arsfeld.xyz behind the tunnel; ACME uses
    # Cloudflare DNS-01 (configured by media.config). caddy needs the acme group
    # to read the issued certificates.
    services.caddy.enable = true;
    users.users.caddy.extraGroups = ["acme"];

    # Host-specific settings
    networking = {
      hostName = "pegasus";
      useNetworkd = true;
      useDHCP = false;
    };

    systemd.network.wait-online.anyInterface = true;

    nixpkgs.hostPlatform = "x86_64-linux";

    # Bootloader - systemd-boot for EFI
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    boot.supportedFilesystems = ["btrfs"];

    # Early OOM killer
    services.earlyoom.enable = true;

    # Disable network wait online service
    systemd.services.NetworkManager-wait-online.enable = false;

    # Systemd boot resilience
    systemd = {
      # Allow boot to continue even if some units fail
      enableEmergencyMode = false; # Don't drop to emergency shell

      # Home Manager needs DNS at boot for nix cache downloads
      services.home-manager-arosenfeld = {
        after = ["nss-lookup.target"];
        wants = ["nss-lookup.target"];
      };
    };

    # SMART monitoring
    services.smartd = {
      enable = true;
      notifications.mail.enable = true;
      notifications.test = true;
    };

    # Weekly scrub of the data pool: verifies every mirror against the checksums
    # and repairs stale/corrupt copies from good ones. Without this, a disk that
    # silently missed writes (see sdg, July 2026) keeps serving stale data until a
    # second failure makes it unrecoverable.
    #
    # Off since 2026-08-31. The HBA breakout lead on phy 7 was bad: it logged
    # link errors and dropped its disk (Z304SS33) under sustained load, and a
    # 16-hour scrub is exactly that load. On 2026-11-15 the lead was taken out
    # of use (Z304SS33 moved to phy 4, the WD to onboard SATA), WDH2Y01G was
    # pulled for failing media (256 reallocated, 72 pending sectors), and the
    # pool went from five disks in RAID1C3 to four with RAID1 data and RAID1C3
    # metadata, converted by hand with
    #
    #   btrfs balance start -dconvert=raid1 -mconvert=raid1c3,soft /mnt/storage
    #   btrfs device remove missing /mnt/storage
    #
    # Re-enable once that conversion has finished and btrfs-health-check has
    # stayed quiet for a week. Persistent=true fires a missed run at the next
    # boot, so enabling it while a balance is running would stack the two.
    #
    # A disk that drops off the bus does not come back until the pool is
    # unmounted and mounted again, or the host is rebooted, and it returns with
    # stale data. Resync it with a single-device scrub:
    #
    #   btrfs scrub start /dev/disk/by-id/ata-<model>_<serial>
    services.btrfs.autoScrub = {
      enable = false;
      fileSystems = ["/mnt/storage"];
      interval = "weekly";
    };

    # Daily pool health check. The scrub above catches corruption but is blind to
    # a device that has *left* the array: when devid 5's SAS link dropped (see
    # sdg, July 2026) the scrub kept reporting success against the four surviving
    # disks, and the pool ran degraded for weeks. smartd is blind to it too --
    # that disk's platters were fine, its lane failed.
    #
    # Two cheap signals:
    #   - `btrfs filesystem show` prints MISSING for a device the pool has lost.
    #   - `btrfs device stats -c` exits non-zero when any error counter is set.
    #
    # -z zeroes the counters after printing, so each run reports only what is new
    # since yesterday rather than re-alerting forever on one historical failure.
    # The cumulative record still lives in SMART, which smartd already watches.
    #
    # A third signal comes before either of those: the HBA's per-lane link error
    # counters. They climb while a cable is going bad and the disk is still on the
    # bus, which is the only warning there is before a drop. They cannot be
    # zeroed, so the last reading is kept under /run and only a change alerts;
    # both reset together at boot.
    systemd.services.btrfs-health-check = let
      btrfs = "${pkgs.btrfs-progs}/bin/btrfs";
      grep = "${pkgs.gnugrep}/bin/grep";
    in {
      description = "Check /mnt/storage for missing devices and new I/O errors";
      # No explicit OnFailure: modules/systemd-email-notify.nix already gives every
      # service onFailure = ["email@%n.service"], which mails status plus recent
      # logs. Failing this unit loudly is the whole notification mechanism.
      unitConfig.RequiresMountsFor = "/mnt/storage";
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "btrfs-health-check";
        RuntimeDirectoryPreserve = true;
      };
      script = ''
        set -u
        rc=0
        if ${btrfs} filesystem show /mnt/storage | ${grep} -q MISSING; then
          echo "DEGRADED: /mnt/storage is missing a device" >&2
          ${btrfs} filesystem show /mnt/storage >&2
          rc=1
        fi
        if ! ${btrfs} device stats -c -z /mnt/storage; then
          echo "new I/O errors on /mnt/storage since last check (counters reset)" >&2
          rc=1
        fi
        for phy in /sys/class/sas_phy/phy-*; do
          [ -e "$phy/invalid_dword_count" ] || continue
          name=''${phy##*/}
          cur="$(cat "$phy/invalid_dword_count") $(cat "$phy/running_disparity_error_count") $(cat "$phy/loss_of_dword_sync_count")"
          prev=$(cat "$RUNTIME_DIRECTORY/$name" 2>/dev/null || echo "0 0 0")
          if [ "$cur" != "$prev" ]; then
            echo "new SAS link errors on $name (invalid_dword disparity loss_of_sync): $prev -> $cur" >&2
            rc=1
          fi
          echo "$cur" > "$RUNTIME_DIRECTORY/$name"
        done
        exit $rc
      '';
    };

    systemd.timers.btrfs-health-check = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    # Avahi for service discovery
    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    # GPG agent configuration
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = false;
      pinentryPackage = pkgs.pinentry-tty;
    };

    # Graphics support for hardware acceleration
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-vaapi-driver
        libvdpau-va-gl
        intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
        vpl-gpu-rt
      ];
    };

    # System state version
    system.stateVersion = "25.05";
  };
}
