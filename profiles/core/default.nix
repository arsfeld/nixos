{
  inputs,
  config,
  pkgs,
  lib,
  self,
  ...
}: {
  age.secrets.attic-netrc.file = "${self}/secrets/attic-netrc.age";

  nix = {
    settings = {
      # Enable flakes and new 'nix' command
      experimental-features = "nix-command flakes";
      # Deduplicate and optimize nix store
      auto-optimise-store = true;

      substituters = [
        "https://nix-community.cachix.org?priority=41" # this is a useful public cache!
        "https://numtide.cachix.org?priority=42" # this is also a useful public cache!
        "https://attic.arsfeld.one/system"
        "https://deploy-rs.cachix.org"
        "https://cosmic.cachix.org/"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "system:3+7hMuZfbXosfHEF4S2RG40v4yBPF03iUQ8UpDqiNBA="
        "deploy-rs.cachix.org-1:xfNobmiwF/vzvK1gpfediPwpdIP0rpDV2rYqx40zdSI="
        "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE="
      ];

      netrc-file = config.age.secrets.attic-netrc.path;
    };

    #registry.nixpkgs.flake = inputs.nixpkgs;

    # This will add each flake input as a registry
    # To make nix3 commands consistent with your flake
    registry = lib.mapAttrs (_: value: {flake = value;}) inputs;

    # This will additionally add your inputs to the system's legacy channels
    # Making legacy nix commands consistent as well, awesome!
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
  };

  security.polkit.enable = true;

  programs.zsh.enable = true;

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  environment.pathsToLink = ["/share/zsh"];

  environment.systemPackages = with pkgs; [
    binutils
    dosfstools
    usbutils
    moreutils
    git
    wget
    vim
    nano
    zsh
    file
    killall
    keychain
    psmisc
    parted
    gptfdisk
    home-manager
    rclone
    tmux
    zpaq
    ncdu_2
    libvirt
    ffmpeg
    exiftool
  ];

  programs.nix-ld.enable = true;

  services.openssh.enable = true;
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "America/Toronto";
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
