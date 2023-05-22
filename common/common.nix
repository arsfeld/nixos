{
  inputs,
  config,
  pkgs,
  lib,
  ...
}: {
  nix = {
    settings = {
      # Enable flakes and new 'nix' command
      experimental-features = "nix-command flakes";
      # Deduplicate and optimize nix store
      auto-optimise-store = true;
    };

    # This will add each flake input as a registry
    # To make nix3 commands consistent with your flake
    registry = lib.mapAttrs (_: value: {flake = value;}) inputs;

    # This will additionally add your inputs to the system's legacy channels
    # Making legacy nix commands consistent as well, awesome!
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
  };

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  environment.pathsToLink = ["/share/zsh"];

  environment.systemPackages = with pkgs; [
    git
    wget
    vim
    nano
    zsh
    file
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

  nix.gc = {
    automatic = true;
    dates = "Sat *-*-* 03:15:00";
    options = "--delete-older-than 30d";
  };

  system.stateVersion = lib.mkDefault "22.05";
}
