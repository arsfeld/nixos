{ lib, config, pkgs, nixpkgs, modulesPath, ... }:

with lib;

{

  services.netdata.enable = true;

  services.caddy = {
    enable = true;
    config = ''
      :80 {
        reverse_proxy /stash/* localhost:9999
      }
    '';
  };


  services.restic.server = {
    enable = true;
    dataDir = "/data/files/Backups/restic";
  };


  services.syncthing = {
    enable = false;
    overrideDevices = true;
    overrideFolders = true;
    user = "media";
    group = "media";
    guiAddress = "0.0.0.0:8384";
    devices = {
      # "picon" = { id = "LLHMFJQ-NRACEUQ-5BK7NHF-XORU7H6-7PEBGUJ-AO2C3L6-LVUD4CJ-YFJHDAS"; };
      "libran" = { id = "BWNS7MB-PWINU5R-BRP4K34-K5RXNAS-KFHEKFQ-AYE4KP2-WXJ6M5A-A4PKHQM"; };
      "oracle" = { id = "QB77MGX-2D7EVZC-WHGBZ2F-RLTTAQJ-GYAYNOM-Q3RTYF3-PL7F435-WO4UWAN"; };
    };
    folders = {
      "data" = {
        id = "data";
        path = "/var/data";
        devices = [ "libran" "oracle" ];
      };
    };
  };
}
