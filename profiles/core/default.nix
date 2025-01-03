{
  inputs,
  config,
  pkgs,
  lib,
  self,
  ...
}: {
  nix = {
    settings = {
      # Enable flakes and new 'nix' command
      experimental-features = "nix-command flakes";
      # Deduplicate and optimize nix store
      auto-optimise-store = true;

      substituters = [
        "https://nix-community.cachix.org?priority=41" # this is a useful public cache!
        "https://numtide.cachix.org?priority=42" # this is also a useful public cache!
        "https://fly-attic.fly.dev/system"
        "https://deploy-rs.cachix.org"
        "https://cosmic.cachix.org/"
        "https://cache.lix.systems/"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "system:qhuLhZgxwERwu+xGKJN0G/46X4rDB1KPxSx8xQrJdBU="
        "deploy-rs.cachix.org-1:xfNobmiwF/vzvK1gpfediPwpdIP0rpDV2rYqx40zdSI="
        "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE="
        "cache.lix.systems:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
      ];
    };

    #registry.nixpkgs.flake = inputs.nixpkgs;

    # This will add each flake input as a registry
    # To make nix3 commands consistent with your flake
    registry = lib.mapAttrs (_: value: {flake = value;}) inputs;

    # This will additionally add your inputs to the system's legacy channels
    # Making legacy nix commands consistent as well, awesome!
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
  };

  nix.package = pkgs.lix;

  security.polkit.enable = true;

  programs.zsh.enable = true;
  programs.fish.enable = true;

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  environment.pathsToLink = ["/share/zsh"];

  environment.systemPackages = with pkgs; [
    # From base profile
    w3m-nographics # needed for the manual anyway
    testdisk # useful for repairing boot problems
    ms-sys # for writing Microsoft boot sectors / MBRs
    efibootmgr
    efivar
    parted
    gptfdisk
    ddrescue
    ccrypt
    cryptsetup # needed for dm-crypt volumes

    # Some text editors.
    vim

    # Some networking tools.
    fuse
    fuse3
    sshfs-fuse
    socat
    screen
    tcpdump

    # Hardware-related tools.
    sdparm
    hdparm
    smartmontools # for diagnosing hard disks
    pciutils
    usbutils
    nvme-cli

    # Some compression/archiver tools.
    unzip
    zip

    binutils
    dosfstools
    duf
    exiftool
    ffmpeg
    file
    git
    gptfdisk
    home-manager
    keychain
    killall
    libvirt
    moreutils
    nano
    ncdu_2
    psmisc
    rclone
    tmux
    usbutils
    wget
    zpaq
    zsh
  ];

  programs.nix-ld.enable = true;

  services.openssh.enable = true;
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "America/Toronto";
  i18n.defaultLocale = "en_CA.UTF-8";
  zramSwap.enable = true;
  networking.firewall.allowedTCPPorts = [22];
  networking.firewall.checkReversePath = "loose";

  hardware.enableRedistributableFirmware = true;

  nix.gc = {
    automatic = true;
    dates = "Sat *-*-* 03:15:00";
    options = "--delete-older-than 30d";
  };

  system.stateVersion = lib.mkDefault "22.05";
}
