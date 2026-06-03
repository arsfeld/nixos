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

  # Grafana Alloy - log shipper (replaces promtail, removed upstream in NixOS 26.05).
  # Scrapes the systemd journal and writes to the local Loki, preserving the original
  # unit/level/hostname labels and the debug-drop filter.
  services.alloy.enable = true;
  environment.etc."alloy/config.alloy".text = ''
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
      rule {
        source_labels = ["__journal__hostname"]
        target_label  = "hostname"
      }
    }

    loki.source.journal "journal" {
      max_age       = "12h"
      relabel_rules = loki.relabel.journal.rules
      forward_to    = [loki.process.filter.receiver]
      labels        = {
        job  = "systemd-journal",
        host = "router",
      }
    }

    loki.process "filter" {
      forward_to = [loki.write.local.receiver]

      // Drop verbose/debug logs to save space
      stage.match {
        selector = "{level=\"debug\"}"
        action   = "drop"
      }
    }

    loki.write "local" {
      endpoint {
        url = "http://localhost:3100/loki/api/v1/push"
      }
    }
  '';

  # NixOS 26.05 removed Grafana's built-in default secret_key. Pin the historical
  # default so existing DB-encrypted values stay decryptable. This router's Grafana
  # holds only local dashboards/datasources (no sensitive secrets), and this value
  # was the public NixOS default everyone shared pre-26.05, so it's not a real secret.
  services.grafana.settings.security.secret_key = "SW2YcwTIb9zpOOhoPsMm";

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
    ];
  };

  # Ensure Alloy starts after Loki is up
  systemd.services.alloy = {
    wants = ["loki.service"];
    after = ["loki.service"];
  };
}
