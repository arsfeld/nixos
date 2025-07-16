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
          shared_store = "filesystem";
        };
        filesystem = {
          directory = "/var/lib/loki/chunks";
        };
      };

      chunk_store_config = {
        max_look_back_period = "168h"; # 7 days
      };

      table_manager = {
        retention_deletes_enabled = true;
        retention_period = "168h"; # 7 days
      };

      limits_config = {
        enforce_metric_name = false;
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
        retention_period = "168h"; # 7 days
        max_entries_limit_per_query = 5000;
        max_query_length = "168h";
        max_query_parallelism = 16;
      };

      compactor = {
        working_directory = "/var/lib/loki/compactor";
        shared_store = "filesystem";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        retention_delete_worker_count = 10;
      };
    };
  };

  # Promtail - Log shipper
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
            # Parse miniupnpd logs
            {
              match = {
                selector = "{unit=\"miniupnpd.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "(?P<timestamp>\\w+ \\d+ \\d+:\\d+:\\d+) .* (?P<action>addentry|delentry): (?P<protocol>\\w+) (?P<ext_port>\\d+) (?P<client_ip>[\\d.]+):(?P<int_port>\\d+)";
                    };
                  }
                  {
                    labels = {
                      action = "";
                      protocol = "";
                      client_ip = "";
                    };
                  }
                  {
                    metrics = {
                      upnp_port_mappings_total = {
                        type = "Counter";
                        description = "Total UPnP port mappings";
                        source = "action";
                        config = {
                          action = "inc";
                          match_all = true;
                        };
                      };
                    };
                  }
                ];
              };
            }
            # Parse blocky DNS logs
            {
              match = {
                selector = "{unit=\"blocky.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "query: (?P<query_type>\\w+) (?P<domain>[^ ]+) from (?P<client>[\\d.:]+)";
                    };
                  }
                  {
                    labels = {
                      query_type = "";
                      client = "";
                    };
                  }
                  {
                    metrics = {
                      dns_queries_total = {
                        type = "Counter";
                        description = "Total DNS queries";
                        source = "query_type";
                        config = {
                          action = "inc";
                          match_all = true;
                        };
                      };
                    };
                  }
                ];
              };
            }
            # Parse blocked domains
            {
              match = {
                selector = "{unit=\"blocky.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "blocked (?P<blocked_domain>[^ ]+) for client (?P<client>[\\d.:]+)";
                    };
                  }
                  {
                    labels = {
                      blocked_domain = "";
                      client = "";
                    };
                  }
                  {
                    metrics = {
                      dns_blocked_total = {
                        type = "Counter";
                        description = "Total blocked DNS queries";
                        source = "blocked_domain";
                        config = {
                          action = "inc";
                          match_all = true;
                        };
                      };
                    };
                  }
                ];
              };
            }
            # Parse nftables logs
            {
              match = {
                selector = "{unit=\"nftables.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "\\[(?P<action>ACCEPT|DROP|REJECT)\\] IN=(?P<in_interface>\\w+)? OUT=(?P<out_interface>\\w+)? SRC=(?P<src_ip>[\\d.]+) DST=(?P<dst_ip>[\\d.]+)";
                    };
                  }
                  {
                    labels = {
                      action = "";
                      in_interface = "";
                      out_interface = "";
                    };
                  }
                ];
              };
            }
            # Parse DHCP logs
            {
              match = {
                selector = "{unit~=\"dhcpd.service|kea-dhcp4.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "(?P<action>DHCPOFFER|DHCPACK|DHCPNAK) on (?P<ip>[\\d.]+) to (?P<mac>[\\w:]+) \\((?P<hostname>[^)]+)\\)";
                    };
                  }
                  {
                    labels = {
                      action = "";
                      ip = "";
                      hostname = "";
                    };
                  }
                ];
              };
            }
            # Parse Tailscale logs
            {
              match = {
                selector = "{unit=\"tailscaled.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "(?P<peer_name>[^:]+): (?P<action>connected|disconnected)";
                    };
                  }
                  {
                    labels = {
                      peer_name = "";
                      action = "";
                    };
                  }
                ];
              };
            }
            # Parse speed test logs
            {
              match = {
                selector = "{unit=\"speedtest.service\"}";
                stages = [
                  {
                    regex = {
                      expression = "Download=(?P<download>[\\d.]+) Mbps, Upload=(?P<upload>[\\d.]+) Mbps, Ping=(?P<ping>[\\d.]+) ms";
                    };
                  }
                  {
                    labels = {
                      test_type = "speedtest";
                    };
                  }
                ];
              };
            }
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