{ config, pkgs, ... }:
{
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

  nix.trustedUsers = [
    "root"
    "@wheel"
  ];

  programs.zsh = {
      enable = true;
      ohMyZsh = {
          enable = true;
          theme = "agnoster";
          plugins = [ "git" "keychain" ];
      };
  };

  environment.systemPackages = with pkgs; [
      wget vim nano zsh file keychain
  ];

  services.openssh.enable = true;
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "America/Toronto";
  zramSwap.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
}
