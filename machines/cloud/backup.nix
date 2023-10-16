{
  lib,
  config,
  pkgs,
  ...
}: {

  age.secrets."restic-password".file = ../../secrets/restic-password.age;
  age.secrets."restic-password".mode = "444";
  
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
      passwordFile = config.age.secrets."restic-password".path;
      repository = "rest:http://storage:8000/cloud";
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };
}