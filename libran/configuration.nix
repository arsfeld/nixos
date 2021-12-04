{ pkgs, modulesPath, ... }: {
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  ec2.hvm = true;

  ec2.efi = true;

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/Toronto";

  boot = {
    kernel.sysctl = {
      "fs.inotify.max_user_watches" = "1048576";
    };
  };

  zramSwap.enable = true;

  networking.firewall.enable = false;
  networking.hostName = "libran";

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
    guiAddress = "0.0.0.0:8384";
    user = "media";
    group = "media";
    devices = {
      # "picon" = { id = "LLHMFJQ-NRACEUQ-5BK7NHF-XORU7H6-7PEBGUJ-AO2C3L6-LVUD4CJ-YFJHDAS"; };
      "striker" = { id = "MKCL44W-QVJTNJ7-HVNG34K-ORECL5N-IUXBE47-2RJIZDE-YVE2RAP-5ABUKQP"; };
    };
    folders = {
      "data" = {
        id = "data";
        path = "/var/data";
        devices = [ "striker" ];
      };
    };
  };

  users.users.arosenfeld = {
    isNormalUser = true;
    home = "/home/arosenfeld";
    shell = pkgs.zsh;
    description = "Alexandre Rosenfeld";
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com" ];
  }; 



  users.users.media.uid = 5000;
  users.users.media.isSystemUser = true;
  users.users.media.group = "media";
  users.groups.media.gid = 5000;
}
