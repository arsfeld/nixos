{
  config,
  pkgs,
  ...
}: {
  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
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

  system.stateVersion = "22.05";
}
