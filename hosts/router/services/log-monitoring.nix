{
  config,
  lib,
  pkgs,
  ...
}: {
  # Loki - Log aggregation system
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9096;
        log_level = "warn"; # Reduce log verbosity
      };

      ingester = {
        lifecycler = {
          address = "127.0.0.1";
          ring = {
            kvstore = {
              store = "inmemory";
            };
            replication_factor = 1;
          };
          final_sleep = "0s";
        };
        chunk_idle_period = "5m";
        chunk_retain_period = "30s";
        max_chunk_age = "1h";
        chunk_target_size = 262144; # 256KB - optimized for router
      };

      schema_config = {
        configs = [
          {
            from = "2023-01-01";
            store = "boltdb-shipper";
            object_store = "filesystem";
            schema = "v11";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
      };

      storage_config = {
        boltdb_shipper = {
          active_index_directory = "/var/lib/loki/boltdb-shipper-active";
          cache_location = "/var/lib/loki/boltdb-shipper-cache";
          cache_ttl = "24h";
        };
        filesystem = {
          directory = "/var/lib/loki/chunks";
        };
      };

      table_manager = {
        retention_deletes_enabled = true;
        retention_period = "168h"; # 7 days
      };

      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
        retention_period = "168h"; # 7 days
        max_entries_limit_per_query = 5000;
        max_query_length = "168h";
        max_query_parallelism = 16;
        allow_structured_metadata = false; # Required for schema v11
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = false; # Disable until we configure delete-request-store
      };
    };
  };

  # Promtail - Log shipper with fixed selectors
  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };

      positions = {
        filename = "/var/lib/promtail/positions.yaml";
      };

      clients = [
        {
          url = "http://localhost:3100/loki/api/v1/push";
          batchwait = "1s";
          batchsize = 1048576; # 1MB
          external_labels = {
            host = "router";
          };
        }
      ];

      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = "router";
            };
          };
          relabel_configs = [
            {
              source_labels = ["__journal__systemd_unit"];
              target_label = "unit";
            }
            {
              source_labels = ["__journal_priority_keyword"];
              target_label = "level";
            }
            {
              source_labels = ["__journal__hostname"];
              target_label = "hostname";
            }
          ];
          pipeline_stages = [
            # Drop verbose/debug logs to save space
            {
              drop = {
                source = "level";
                value = "debug";
              };
            }
          ];
        }
      ];
    };
  };

  # Update Grafana to include Loki datasource
  services.grafana.provision.datasources.settings.datasources = lib.mkAfter [
    {
      name = "Loki";
      type = "loki";
      access = "proxy";
      url = "http://localhost:3100";
      isDefault = false;
      jsonData = {
        maxLines = 1000;
        derivedFields = [
          {
            datasourceUid = "prometheus";
            matcherRegex = "(?P<trace_id>\\w+)";
            name = "TraceID";
            url = "$${__value.raw}";
          }
        ];
      };
    }
  ];

  # Ensure log directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0755 loki loki -"
    "d /var/lib/loki/chunks 0755 loki loki -"
    "d /var/lib/loki/boltdb-shipper-active 0755 loki loki -"
    "d /var/lib/loki/boltdb-shipper-cache 0755 loki loki -"
    "d /var/lib/loki/compactor 0755 loki loki -"
    "d /var/lib/promtail 0755 promtail promtail -"
  ];

  # Add log rotation for Loki's own logs
  services.logrotate.settings.loki = {
    files = ["/var/log/loki.log"];
    frequency = "daily";
    rotate = 3;
    compress = true;
    delaycompress = true;
    notifempty = true;
    create = "0644 loki loki";
  };

  # Open ports for internal access (only on LAN interface)
  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [
      3100 # Loki
      9080 # Promtail
    ];
  };
}