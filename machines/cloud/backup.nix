{config, ...}: {
  age.secrets."restic-password".file = ../../secrets/restic-password.age;
  age.secrets."restic-password".mode = "444";

  age.secrets."restic-rest-cloud".file = ../../secrets/restic-rest-cloud.age;
  age.secrets."restic-rest-cloud".mode = "444";

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
      environmentFile = config.age.secrets."restic-rest-cloud".path;
      passwordFile = config.age.secrets."restic-password".path;
      repository = "rest:https://restic.arsfeld.one/cloud";
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };
}
