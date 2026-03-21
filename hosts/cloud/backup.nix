{
  config,
  self,
  ...
}: {
  sops.secrets."restic-password" = {
    mode = "0444";
    sopsFile = config.constellation.sops.commonSopsFile;
  };

  sops.secrets."restic-rest-cloud".mode = "0444";

  services.restic.backups = {
    cloud = {
      paths = [
        "/var/lib"
        "/root"
      ];
      exclude = [
        # very large paths
        "/var/lib/docker"
        "/var/lib/systemd"
        "/var/lib/libvirt"

        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      environmentFile = config.sops.secrets."restic-rest-cloud".path;
      passwordFile = config.sops.secrets."restic-password".path;
      repository = "rest:https://restic.arsfeld.one/cloud";
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };
}
