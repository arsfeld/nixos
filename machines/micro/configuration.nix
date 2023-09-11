{config, ...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ../../common/services.nix
    ../../common/acme.nix
    ./hardware-configuration.nix
    ../../common/sites/arsfeld.one.nix
    ../../common/sites/rosenfeld.one.nix
    ../../common/sites/rosenfeld.blog.nix
    ../../common/sites/arsfeld.dev.nix
  ];

  services.netdata.enable = true;

  services.adguardhome = {
    enable = true;
    settings = {
      users = [
        {
          name = "admin";
          password = "$2a$10$ZqHeXubJoB7II0u/39Byiu4McdkjCoqurctIlMikm4kyILQvEevEO";
        }
      ];
      bind_port = 3000;
      dns = {
        bind_hosts = ["0.0.0.0"];
        port = 53;
        rewrites = [
          {
            domain = "*.arsfeld.one";
            answer = "100.101.207.61";
          }
        ];
        upstream_dns = ["1.1.1.1" "1.0.0.1"];
      };
    };
  };

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

  # age.secrets.smtp_password.file = ../secrets/smtp_password.age;

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    ghost = {
      image = "ghost:5";
      volumes = ["/var/lib/ghost/content:/var/lib/ghost/content"];
      environment = {
        url = "https://blog.arsfeld.dev";
        database__client = "sqlite3";
        database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
        database__useNullAsDefault = "true";
        # mail__transport = "SMTP";
        # mail__host = "wednesday.mxrouting.net";
        # mail__port = "587";
        # mail__secure = "true";
        # mail__auth__user = "admin@arsfeld.one";
        # mail__auth__pass = builtins.readFile config.age.secrets.smtp_password.path;
      };
      ports = ["2368:2368"];
    };

    yarr = {
      image = "arsfeld/yarr";
      volumes = ["/var/lib/yarr:/data"];
      ports = ["7070:7070"];
    };
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
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];
  networking.hostName = "micro";
}
