{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

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

  nixpkgs.config.allowUnfree = true;
  networking.firewall.allowPing = true;
  networking.firewall.enable = false;
  networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];
  services.openssh.enable = true;

  services.github-runner = {
    enable = false;
    url = "https://github.com/arsfeld/ztcf";
    tokenFile = "/etc/github.token";
    extraPackages = [ pkgs.docker ];
  };

  networking.hostName = "oracle";

  zramSwap.enable = true;

  virtualisation.lxd.enable = true;

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
  };

  services.zerotierone = {
    enable = true;
    joinNetworks = [ "35c192ce9b7b5113"] ;
  };

  programs.zsh = {
      enable = true;
      ohMyZsh = {
          enable = true;
          theme = "agnoster";
      };
  };

  services.syncthing = {
    enable = true;
    overrideDevices = true;
    overrideFolders = true;
    user = "media";
    group = "media";
    guiAddress = "0.0.0.0:8384";
    devices = {
      "libran" = { id = "BWNS7MB-PWINU5R-BRP4K34-K5RXNAS-KFHEKFQ-AYE4KP2-WXJ6M5A-A4PKHQM"; };
      "striker" = { id = "MKCL44W-QVJTNJ7-HVNG34K-ORECL5N-IUXBE47-2RJIZDE-YVE2RAP-5ABUKQP"; };
    };
    folders = {
      "data" = {
        id = "data";
        path = "/var/data";
        devices = [ "libran" "striker" ];
      };
    };
  };

  users.users.arosenfeld = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "docker" "lxd" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w" ]
;
    uid = 1000;
  };
  users.groups.arosenfeld.gid = 1000;


  users.users.media.uid = 5000;
  users.users.media.isSystemUser = true;
  users.users.media.group = "media";
  users.groups.media.gid = 5000;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com" 
  ];
}
