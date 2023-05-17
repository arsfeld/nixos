{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  homeDir = "/mnt/data/homes/arosenfeld/Cloud";
  configFile = "${homeDir}/rclone.conf";
  rcloneOptions = "--fast-list --stats-one-line --verbose --config ${configFile}";
  providers = {
    dropbox = "Dropbox";
    gdrive = "Google Drive";
    onedrive = "One Drive";
    box = "Box";
  };
  mkSyncWrapper = provider: folder:
    pkgs.writeShellScriptBin "sync-${provider}-reconnect" ''
      ${pkgs.rclone}/bin/rclone config --config ${configFile} reconnect ${provider}:
    '';
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
          ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} ${provider}: "${homeDir}/${folder}"
        '';
      };
    })
    providers));
in {
  systemd.timers = timers;
  systemd.services = services;
  environment.systemPackages = with pkgs; (mapAttrsToList mkSyncWrapper providers);
}
