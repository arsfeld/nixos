{config, ...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ../../common/services.nix
    ../../common/acme.nix
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

  age.secrets."restic-password".file = ../../secrets/restic-password.age;
  age.secrets."restic-password".mode = "444";

  services.restic.backups = {
    micro = {
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
      repository = "rest:http://storage:8000/micro";
      initialize = true;
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };

  networking.firewall.enable = false;
  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];
  networking.hostName = "micro";
}
