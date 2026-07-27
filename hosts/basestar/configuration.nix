{
  pkgs,
  config,
  self,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./services
    ./services.nix
  ];

  constellation.podman.enable = true;
  constellation.sites.arsfeld-dev.enable = true;
  constellation.sites.rosenfeld-one = {
    enable = true;
    dexUpstream = "galactica.bat-boa.ts.net:36958";
    usersUpstream = "galactica.bat-boa.ts.net:64459";
  };

  # Blog service
  services.blog = {
    enable = true;
    domain = "blog.arsfeld.dev";
  };

  # Enable self-hosted Plausible Analytics
  services.plausible-analytics = {
    enable = true;
    domain = "plausible.arsfeld.dev";
  };

  # Ensure ClickHouse system log TTLs are set (prevents unbounded growth)
  # TTLs are applied via SQL after ClickHouse starts
  systemd.services.clickhouse-ttl = {
    description = "Set ClickHouse system log TTLs";
    after = ["clickhouse.service"];
    wants = ["clickhouse.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for ClickHouse to be ready
      sleep 5
      ${pkgs.clickhouse}/bin/clickhouse-client --query "ALTER TABLE system.trace_log MODIFY TTL event_date + INTERVAL 3 DAY" || true
      ${pkgs.clickhouse}/bin/clickhouse-client --query "ALTER TABLE system.query_log MODIFY TTL event_date + INTERVAL 7 DAY" || true
      ${pkgs.clickhouse}/bin/clickhouse-client --query "ALTER TABLE system.metric_log MODIFY TTL event_date + INTERVAL 7 DAY" || true
      ${pkgs.clickhouse}/bin/clickhouse-client --query "ALTER TABLE system.asynchronous_metric_log MODIFY TTL event_date + INTERVAL 7 DAY" || true
      ${pkgs.clickhouse}/bin/clickhouse-client --query "ALTER TABLE system.part_log MODIFY TTL event_date + INTERVAL 7 DAY" || true

      # ClickHouse renames a system log table aside (trace_log -> trace_log_N) whenever
      # it starts up with an incompatible schema, then creates a fresh empty one. The
      # renamed copy keeps all its rows, inherits no TTL, and is never matched by the
      # ALTERs above — so it grows without bound. basestar accumulated 23GiB this way
      # across trace_log_3 (March) and trace_log_7 (May) while the live trace_log sat
      # correctly bounded at 377MiB. Apply the same retention to any orphans.
      ${pkgs.clickhouse}/bin/clickhouse-client --query "
        SELECT name FROM system.tables
        WHERE database = 'system'
          AND match(name, '^(trace|query|metric|asynchronous_metric|part)_log_[0-9]+$')
          AND total_bytes > 0
      " | while read -r tbl; do
        [ -n "''$tbl" ] || continue
        echo "applying retention to orphaned system.''$tbl"
        ${pkgs.clickhouse}/bin/clickhouse-client --query \
          "ALTER TABLE system.\"''$tbl\" MODIFY TTL event_date + INTERVAL 3 DAY" || true
      done
    '';
  };

  # Enable Planka kanban board
  services.planka-board = {
    enable = true;
    domain = "planka.arsfeld.dev";
  };

  # Enable Siyuan note-taking application
  services.siyuan-notes = {
    enable = true;
    domain = "siyuan.arsfeld.dev";
  };

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  # Backrest replaces the previous rustic profile (which wrote to the same
  # repo on a weekly cadence). Daily cron is finer resolution.
  # Retention left empty to match the old rustic behavior — no client-side
  # prune — until Phase B decides on a coordinated retention policy for
  # the shared storage repo.
  constellation.backrest = {
    enable = true;
    repos = {
      storage = {
        uri = "rest:http://galactica.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
      };
      pegasus = {
        uri = "rest:http://pegasus.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
      };
    };
    plans.system = {
      repo = "storage";
      paths = ["/var/lib" "/var/data" "/home" "/root"];
      excludes = [
        "/var/lib/docker"
        "/var/lib/containers"
        "/var/lib/systemd"
        "/var/lib/libvirt"
        "/var/lib/lxcfs"
        "/var/cache"
        "/nix"
        "/mnt"
        "**/.cache"
        "**/.nix-profile"
      ];
      excludeIfPresent = [".nobackup" "CACHEDIR.TAG"];
      schedule.cron = "30 3 * * *";
    };
  };

  # Gateway for basestar services — auth forwarded to galactica's Authelia via tsnsrv
  media.gateway.enable = true;
  media.gateway.authHost = "auth.bat-boa.ts.net";
  media.gateway.authPort = 443;

  # Enable sops-nix secret management
  constellation.sops.enable = true;

  # Define secrets using standard sops-nix options
  sops.secrets = {
    # Host-specific secrets (use defaultSopsFile set by constellation.sops)
    siyuan-auth-code = {
      owner = "root";
      group = "root";
    };
  };

  media.config = {
    enable = true;
    domain = "arsfeld.one";
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  #boot.kernelPackages = pkgs.linuxPackages_latest;

  #services.blocky.settings.customDNS.mapping."arsfeld.one" = "100.118.254.136";
  #services.redis.servers.blocky.bind = "100.66.38.77";
  #services.redis.servers.blocky.port = 6378;

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

  boot.tmp.cleanOnBoot = true;
  networking.hostName = "basestar";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443];
    # Trust the podman container bridge so containers can reach host services
    # (system postgres, native SearXNG) via host.containers.internal. External
    # access stays restricted by this firewall + the OCI cloud firewall.
    trustedInterfaces = ["podman0"];
  };

  # This should be overriden by tailscale at some point
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];

  services.fail2ban = {
    enable = true;
    ignoreIP = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
    ];
  };

  security.acme.certs."arsfeld.dev" = {
    extraDomainNames = ["*.arsfeld.dev"];
  };

  # Plausible will use the wildcard certificate above
}
