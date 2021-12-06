{ config, pkgs, ... }:
{
  imports = [
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./hardware-configuration.nix
  ];

  networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];

  services.github-runner = {
    enable = false;
    url = "https://github.com/arsfeld/ztcf";
    tokenFile = "/etc/github.token";
    extraPackages = [ pkgs.docker ];
  };

  networking.hostName = "oracle";

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
