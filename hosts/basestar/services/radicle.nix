{
  config,
  lib,
  pkgs,
  ...
}: let
  nodeDomain = "seed.arsfeld.dev";
  webDomain = "radicle.arsfeld.dev";
  radHome = "/var/lib/radicle/.radicle";
  nodePort = 8776;
  httpPort = 8080;
  explorer = pkgs.radicle-explorer.withConfig {
    preferredSeeds = [
      {
        hostname = webDomain;
        port = 443;
        scheme = "https";
      }
    ];
  };

  radicleConfig = pkgs.writeText "radicle-seed-config.json" (builtins.toJSON {
    publicExplorer = "https://app.radicle.xyz/nodes/$host/$rid$path";
    preferredSeeds = [
      "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@iris.radicle.xyz:8776"
      "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@irisradizskwweumpydlj4oammoshkxxjur3ztcmo7cou5emc6s5lfid.onion:8776"
      "z6Mkmqogy2qEM2ummccUthFEaaHvyYmYBYh3dbe9W4ebScxo@rosa.radicle.xyz:8776"
      "z6Mkmqogy2qEM2ummccUthFEaaHvyYmYBYh3dbe9W4ebScxo@rosarad5bxgdlgjnzzjygnsxrwxmoaj4vn7xinlstwglxvyt64jlnhyd.onion:8776"
    ];
    web.pinned.repositories = [];
    cli.hints = true;
    node = {
      alias = nodeDomain;
      listen = ["0.0.0.0:${toString nodePort}"];
      peers.type = "dynamic";
      connect = [];
      externalAddresses = ["${nodeDomain}:${toString nodePort}"];
      network = "main";
      log = "INFO";
      relay = "auto";
      workers = 8;
      limits = {
        routingMaxSize = 1000;
        routingMaxAge = 604800;
        gossipMaxAge = 1209600;
        fetchConcurrency = 1;
        maxOpenFiles = 4096;
        rate = {
          inbound = {
            fillRate = 5.0;
            capacity = 1024;
          };
          outbound = {
            fillRate = 10.0;
            capacity = 2048;
          };
        };
        connection = {
          inbound = 128;
          outbound = 16;
        };
        fetchPackReceive = "500.0 MiB";
      };
      seedingPolicy = {
        default = "block";
      };
    };
  });

  radEnv = {
    RAD_HOME = radHome;
    HOME = "/var/lib/radicle";
  };
in {
  users.groups.seed = {};
  users.users.seed = {
    group = "seed";
    home = "/var/lib/radicle";
    isSystemUser = true;
    createHome = true;
    shell = "${pkgs.shadow}/bin/nologin";
  };

  environment.systemPackages = [
    pkgs.radicle-node
    pkgs.radicle-httpd
  ];

  networking.firewall.allowedTCPPorts = [nodePort];

  systemd.services.radicle-init = {
    description = "Initialize Radicle seed profile";
    wantedBy = ["multi-user.target"];
    before = ["radicle-node.service" "radicle-httpd.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "seed";
      Group = "seed";
      StateDirectory = "radicle";
      StateDirectoryMode = "0700";
      UMask = "0077";
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") radEnv;
    };
    script = ''
      set -euo pipefail

      mkdir -p "$RAD_HOME"

      if [ ! -f "$RAD_HOME/keys/radicle" ]; then
        ${pkgs.radicle-node}/bin/rad auth --alias ${nodeDomain} --stdin < /dev/null
      fi

      install -m 0644 ${radicleConfig} "$RAD_HOME/config.json"
    '';
  };

  systemd.services.radicle-node = {
    description = "Radicle seed node";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "radicle-init.service"];
    wants = ["network-online.target" "radicle-init.service"];
    serviceConfig = {
      User = "seed";
      Group = "seed";
      WorkingDirectory = "/var/lib/radicle";
      StateDirectory = "radicle";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "10s";
      LimitNOFILE = 4096;
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") radEnv;
      ExecStart = "${pkgs.radicle-node}/bin/rad node start --foreground --path ${pkgs.radicle-node}/bin/radicle-node -- --log-logger systemd";
    };
  };

  systemd.services.radicle-httpd = {
    description = "Radicle HTTP daemon";
    wantedBy = ["multi-user.target"];
    after = ["radicle-node.service"];
    wants = ["radicle-node.service"];
    serviceConfig = {
      User = "seed";
      Group = "seed";
      WorkingDirectory = "/var/lib/radicle";
      StateDirectory = "radicle";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") radEnv;
      ExecStart = "${pkgs.radicle-httpd}/bin/radicle-httpd --listen 127.0.0.1:${toString httpPort}";
    };
  };

  services.caddy.enable = true;
  services.caddy.virtualHosts.${webDomain} = {
    useACMEHost = "arsfeld.dev";
    extraConfig = ''
      handle /api* {
        reverse_proxy 127.0.0.1:${toString httpPort}
      }

      handle /raw* {
        reverse_proxy 127.0.0.1:${toString httpPort}
      }

      @radicleGit path_regexp ^/rad:.*
      handle @radicleGit {
        reverse_proxy 127.0.0.1:${toString httpPort}
      }

      handle {
        root * ${explorer}
        try_files {path} /index.html
        file_server
      }

      encode zstd gzip
    '';
  };
}
