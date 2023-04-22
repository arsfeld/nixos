{...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ../../common/services.nix
    ./hardware-configuration.nix
    ../../common/sites/arsfeld.one.nix
    ../../common/sites/rosenfeld.one.nix
  ];

  users.users.caddy.extraGroups = ["acme"];

  services.caddy = {
    enable = true;
  };

  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://bitwarden.arsfeld.one";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
    };
  };

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    yarr = {
      image = "arsfeld/yarr";
      volumes = ["/var/lib/yarr:/data"];
      ports = ["7070:7070"];
    };
  };

  services.adguardhome = {
    enable = true;
  };

  services.restic.backups = {
    micro = {
      paths = ["/var/lib"];
      repository = "rest:http://storage:8000/micro-backup";
      passwordFile = "/etc/secrets/restic";
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };

  services.borgbackup.jobs.micro = {
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
    encryption.mode = "none";
    compression = "auto,zstd";
    repo = "borg@storage:micro";
  };

  networking.firewall.enable = false;
  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];
  networking.hostName = "micro";
}
