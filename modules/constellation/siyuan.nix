{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.constellation.siyuan;
in {
  options.constellation.siyuan = {
    enable = lib.mkEnableOption "Siyuan note-taking application";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "siyuan.arsfeld.dev";
      description = "Domain for Siyuan";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/siyuan";
      description = "Data directory for Siyuan";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 6806;
      description = "Port for Siyuan to listen on";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "siyuan";
      description = "User to run Siyuan as";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "siyuan";
      description = "Group to run Siyuan as";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create necessary directories and user
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/workspace 0755 ${cfg.user} ${cfg.group} -"
      "d /run/siyuan 0700 root root -"
    ];

    # Siyuan container
    virtualisation.oci-containers.containers.siyuan = {
      image = "b3log/siyuan:latest";
      environment = {
        TZ = config.time.timeZone;
      };
      environmentFiles = [
        "/run/siyuan/env"
      ];
      volumes = [
        "${cfg.dataDir}/workspace:/siyuan/workspace"
      ];
      ports = [
        "${toString cfg.port}:6806"
      ];
      cmd = [
        "--workspace=/siyuan/workspace/"
        "--accessAuthCode=$SIYUAN_ACCESS_AUTH_CODE"
      ];
    };

    # Create environment file for Siyuan container
    systemd.services.docker-siyuan = {
      preStart = lib.mkAfter ''
        # Ensure proper ownership
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}

        # Create environment file with SIYUAN_ACCESS_AUTH_CODE variable
        cat > /run/siyuan/env <<EOF
        SIYUAN_ACCESS_AUTH_CODE=$(cat ${config.sops.secrets.siyuan-auth-code.path})
        EOF
        chmod 600 /run/siyuan/env
      '';
    };

    # Caddy reverse proxy
    services.caddy.virtualHosts.${cfg.domain} = {
      useACMEHost = "arsfeld.dev";
      extraConfig = ''
        encode zstd gzip

        header {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
        }

        reverse_proxy localhost:${toString cfg.port} {
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
          header_up Host {host}
          header_up X-Forwarded-Host {host}
        }
      '';
    };

    # Secrets
    # NOTE: siyuan-auth-code is now managed via sops on hosts that enable it
    # For hosts using ragenix, keep this configuration:
    age.secrets = lib.mkIf (!config.sops.secrets ? siyuan-auth-code) {
      siyuan-auth-code = {
        file = ../../secrets/siyuan-auth-code.age;
        owner = "root";
        group = "root";
      };
    };
  };
}
