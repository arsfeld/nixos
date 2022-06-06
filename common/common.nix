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
  ];

  services.openssh.enable = true;
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "America/Toronto";
  zramSwap.enable = true;
  networking.firewall.allowedTCPPorts = [22];
  networking.firewall.checkReversePath = "loose";

  system.stateVersion = "22.05";
}
