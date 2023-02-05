{...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ../../common/services.nix
    ./hardware-configuration.nix
    ./sites/arsfeld.one.nix
  ];

  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };

  services.caddy = {
    enable = true;
  };

  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://bitwarden.arsfeld.one";
      SIGNUPS_ALLOWED = true;
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

  networking.firewall.enable = false;
  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.hostName = "micro";
}
