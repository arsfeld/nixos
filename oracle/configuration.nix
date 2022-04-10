{ config, pkgs, ... }:
{
  imports = [
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./hardware-configuration.nix
    ./caddy.nix
  ];

  networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];
  networking.hostId = "95760b5e";

  networking.firewall.trustedInterfaces = [ "zt7nnoth4i" ];

  security.sudo.wheelNeedsPassword = false;

  services.github-runner = {
    enable = false;
    url = "https://github.com/arsfeld/ztcf";
    tokenFile = "/etc/github.token";
    extraPackages = [ pkgs.docker ];
  };

  fileSystems."/mnt/data" = {
    device = "//209.209.8.178/data";
    fsType = "cifs";
    options =
      let
        # this line prevents hanging on network split
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
      in
      [ "${automount_opts},user=media,pass=mUzf3l7z1ml7Jgs8,uid=media,gid=media" ];
  };

  # services.borgbackup.jobs = {
  #   # for a local backup
  #   dataBackup = {
  #     paths = "/var/data";
  #     repo = "/data/files/Backups/borg";
  #     compression = "zstd";
  #     encryption.mode = "none";
  #     startAt = "daily";
  #   };
  # };

  networking.hostName = "oracle";

  /*
    services.nebula.networks = {
    home = {
    isLighthouse = true;
    settings =
    {
    punchy = {
    punch = true;
    };
    };
    firewall = {
    outbound =
    [
    {
    host = "any";
    port = "any";
    proto = "any";
    }
    ];
    inbound =
    [
    {
    host = "any";
    port = "any";
    proto = "any";
    }
    ];
    };
    ca = "/etc/nebula/ca.crt";
    cert = "/etc/nebula/lighthouse.crt";
    key = "/etc/nebula/lighthouse.key";
    };
    };
  */

  services.syncthing = {
    enable = false;
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
}
