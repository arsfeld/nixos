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

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  programs.starship = {
    enable = true;
  };

  programs.zsh = {
      enable = true;
      ohMyZsh = {
          enable = false;
          theme = "agnoster";
          plugins = [ "git" "keychain" ];
      };
      shellInit = ''
        zstyle :omz:plugins:keychain agents gpg,ssh
      '';
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
