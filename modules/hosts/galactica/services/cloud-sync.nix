{
  configurations.nixos.galactica.module = {
    lib,
    pkgs,
    ...
  }: let
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
    mkService = provider: folder: {
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "arosenfeld";
      script = ''
        ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} ${provider}: "${homeDir}/${folder}"
      '';
    };
    mkTimer = provider: {
      wantedBy = ["timers.target"];
      partOf = ["sync-${provider}.service"];
      timerConfig.OnCalendar = "weekly";
      timerConfig.RandomizedDelaySec = "120m";
    };
  in {
    systemd.timers = lib.mapAttrs' (provider: _: lib.nameValuePair "sync-${provider}" (mkTimer provider)) providers;
    systemd.services = lib.mapAttrs' (provider: folder: lib.nameValuePair "sync-${provider}" (mkService provider folder)) providers;
    environment.systemPackages = lib.mapAttrsToList mkSyncWrapper providers;
  };
}
