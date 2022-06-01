{
  config,
  pkgs,
  ...
}: {
  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  boot = {
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = "1048576";
    };
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
  ];

  services.openssh.enable = true;
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "America/Toronto";
  zramSwap.enable = true;
  networking.firewall.allowedTCPPorts = [22];
  networking.firewall.checkReversePath = "loose";

  system.stateVersion = "22.05";
}
