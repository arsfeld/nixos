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
  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/01cdd316-d539-42a4-b87c-de5d14d40c94";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=30s"
    ];
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
