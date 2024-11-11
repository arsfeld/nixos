{
  config,
  pkgs,
  ...
}: {
  # prometheus: port 3020 (8020)
  #
  services.prometheus = {
    port = 3020;
    enable = true;

    exporters = {
      node = {
        port = 3021;
        enabledCollectors = ["systemd"];
        enable = true;
      };
    };

    # ingest the published nodes
    scrapeConfigs = [
      {
        job_name = "nodes";
        static_configs = [
          {
            targets = [
              "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
            ];
          }
        ];
      }
    ];
  };

  # loki: port 3030 (8030)
  #
  services.loki = {
    enable = true;
    configuration = {
      server.http_listen_port = 3030;
      auth_enabled = false;

      common = {
        ring = {
          instance_addr = "127.0.0.1";
          kvstore = {
            store = "inmemory";
          };
        };
        replication_factor = 1;
        path_prefix = "/var/lib/loki";
      };

      schema_config = {
        configs = [
          {
            from = "2020-05-15";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
      };

      storage_config = {
        filesystem = {
          directory = "/var/lib/loki/chunks";
        };
      };
    };
  };

  # promtail: port 3031 (8031)
  #
  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 3031;
        grpc_listen_port = 0;
      };
      positions = {
        filename = "/tmp/positions.yaml";
      };
      clients = [
        {
          url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
        }
      ];
      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = "storage";
            };
          };
          relabel_configs = [
            {
              source_labels = ["__journal__systemd_unit"];
              target_label = "unit";
            }
          ];
        }
      ];
    };
    # extraFlags
  };

  # grafana: port 3010 (8010)
  #
  services.grafana = {
    # WARNING: this should match nginx setup!
    # prevents "Request origin is not authorized"
    #rootUrl = "http://192.168.1.10:8010"; # helps with nginx / ws / live

    enable = true;

    settings = {
      server = {
        protocol = "http";
        addr = "0.0.0.0";
        http_port = 3010;
      };
      analytics.reporting_enable = false;

      users = {
        allow_sign_up = false;
        auto_assign_org = true;
        auto_assign_org_role = "Editor";
      };
      "auth.proxy" = {
        enabled = true;
        header_name = "X-Tailscale-User";
        header_property = "username";
        auto_sign_up = true;
        sync_ttl = 0;
        whitelist = "127.0.0.1";
        headers = ["Email:X-Tailscale-User-LoginName" "Name:X-Tailscale-User-DisplayName"];
        enable_login_token = true;
      };
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
          }
        ];
      };
    };
  };
}
