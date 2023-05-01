{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: let
  rcloneOptions = "--fast-list --stats-one-line --verbose";
  homeDir = "/mnt/data/homes/arosenfeld/Cloud";
  providers = {
    dropbox = "Dropbox";
    gdrive = "Google Drive";
    onedrive = "One Drive";
    box = "Box";
  };
  timers = builtins.foldl' (x: y: x // y) {} (builtins.attrValues (builtins.mapAttrs (provider: folder: {
      "sync-${provider}" = {
        wantedBy = ["timers.target"];
        partOf = ["sync-${provider}.service"];
        timerConfig.OnCalendar = "daily";
        timerConfig.RandomizedDelaySec = "30m";
      };
    })
    providers));
  services = builtins.foldl' (x: y: x // y) {} (builtins.attrValues (builtins.mapAttrs (provider: folder: {
      "sync-${provider}" = {
        serviceConfig.Type = "oneshot";
        serviceConfig.User = "arosenfeld";
        script = ''
          ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} dropbox: ${homeDir}/${folder}
        '';
      };
    })
    providers));
in {
  systemd.timers = timers;
  systemd.services = services;
}
