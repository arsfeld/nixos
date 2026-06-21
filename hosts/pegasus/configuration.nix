{
  lib,
  pkgs,
  config,
  self,
  inputs,
  ...
}:
with lib; {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./services
    ./backup
  ];

  # Enable all constellation modules
  constellation = {
    sops.enable = true;
    common.enable = true;
    email.enable = true;
    podman.enable = true;
    virtualization.enable = true;
  };

  # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
  # publishes). owner + mode let the user-mode script read it directly.
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
  };

  # The media containers mount mediaVolumes (/media + /files). galactica has a
  # /mnt/storage/files share; pegasus does not, and podman refuses to bind-mount
  # a missing source. Create an empty one so Plex/Stash/mydia can start.
  systemd.tmpfiles.rules = [
    "d /mnt/storage/files 0775 media media -"
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

  # mediaSync is DISABLED for the duration of the move.
  #
  # Its cleanup step deletes any unmarked *directory* under /mnt/storage/media,
  # and when galactica is unreachable the remote marker scan fails so the
  # "keep" set is empty — meaning the nightly run would wipe synced content
  # (e.g. the Series/The Boys folder) the moment galactica goes offline.
  #
  # During the move, pegasus is populated by a one-off rsync instead (The Boys
  # + the recent slice of the Stash/Vault library). Re-enable this after
  # galactica is back online; loose Vault files survive cleanup (it skips
  # files), but re-marking or relocating rsynced Vault *subdirs* avoids them
  # being cleaned on the first managed run.
  constellation.mediaSync.enable = false;

  # Media stack with pegasus's own public domain (arsfeld.xyz), served over a
  # Cloudflare tunnel (hosts/pegasus/services/cloudflared.nix). This makes Plex,
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

    # Use DHCP as fallback on all interfaces
    useDHCP = true;

    # Ensure network doesn't block boot
    dhcpcd = {
      wait = "background"; # Don't wait for DHCP during boot
      extraConfig = ''
        # Shorter timeout for faster boot
        timeout 10
        # Don't wait for IPv6
        noipv6rs
        # Continue even without lease
        fallback
      '';
    };
  };

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
}
