{
  lib,
  config,
  pkgs,
  self,
  ...
}: let
  rustic = pkgs.writeShellApplication {
    name = "restic";
    runtimeInputs = [pkgs.rclone];
    text = ''
      for v in $(printenv | grep RESTIC_)
      do
          export "RUSTIC_''${v#RESTIC_}"
      done
      exec ${pkgs.rustic-rs}/bin/rustic "$@"
    '';
  };
  glob = [
    # very large paths
    "!/var/lib/docker"
    "!/var/lib/systemd"
    "!/var/lib/libvirt"

    "!**/.cache"
    "!**/.nix-profile"
  ];
  opts = {
    #package = rustic;
    extraBackupArgs = [
      #"--glob-file=${pkgs.writeText "glob-file" (lib.concatStringsSep "\n" glob)}"
      #"--progress-interval=1s"
    ];
    paths = [
      "/mnt/data/homes"
      "/var/lib"
      "/var/data"
      "/root"
    ];
    exclude = [
      # very large paths
      "/var/lib/docker"
      "/var/lib/systemd"
      "/var/lib/libvirt"

      "**/.cache"
      "**/.nix-profile"
    ];
    rcloneConfigFile = config.age.secrets."rclone-idrive".path;
    passwordFile = config.age.secrets."restic-password".path;
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "5h";
    };
  };
in
  with lib; {
    age.secrets."rclone-idrive".file = ../../secrets/rclone-idrive.age;
    age.secrets."rclone-idrive".mode = "444";

    age.secrets."restic-password".file = ../../secrets/restic-password.age;
    age.secrets."restic-password".mode = "444";

    services.restic.backups = {
      # nas = {
      #   paths = ["/var/data"];
      #   repository = "/mnt/data/backups/restic";
      #   passwordFile = "/etc/secrets/restic";
      #   timerConfig = {
      #     OnCalendar = "daily";
      #     RandomizedDelaySec = "5h";
      #   };
      # };

      idrive =
        opts
        // {
          repository = "rclone:idrive:arosenfeld";
        };

      # local =
      #   opts
      #   // {
      #     repository = "/mnt/backup/restic";
      #   };
    };
  }
