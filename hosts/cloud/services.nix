{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = "arsfeld.one";
  authDomain = "rosenfeld.one";
  autheliaConfig = "arsfeld.one";
  ports = (import "${self}/common/services.nix" {}).ports;
in {
  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";

  services.tsnsrv = {
    enable = true;
    defaults = {
      authKeyPath = config.age.secrets.tailscale-key.path;
    };
  };

  users.users.beszel-agent = {
    group = "beszel-agent";
    home = "/var/lib/beszel-agent";
    isSystemUser = true;
    createHome = true;
  };

  users.groups.beszel-agent.name = "beszel-agent";

  systemd.services.beszel-agent = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Environment = [
        "PORT=45876"
        "KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGKIjUSMdRqYMmZopjoXBVbEW2SpjE4mxrPclsnQCvW9'"
      ];
      User = "beszel-agent";
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      WorkingDirectory = "/var/lib/beszel-agent";
    };
  };

  age.secrets.dex-clients-tailscale-secret.file = "${self}/secrets/dex-clients-tailscale-secret.age";

  services.dex = {
    enable = true;
    environmentFile = config.age.secrets.lldap-env.path;
    settings = {
      # External url
      issuer = "https://${authDomain}";
      storage = {
        type = "sqlite3";
        config.host = "/var/lib/dex/dex.db";
      };
      web = {
        http = "127.0.0.1:${toString ports.dex}";
      };
      enablePasswordDB = true;
      staticClients = [
        {
          id = "tailscale";
          name = "Tailscale";
          redirectURIs = ["https://login.tailscale.com/a/oauth_response"];
          secretFile = config.age.secrets.dex-clients-tailscale-secret.path;
        }
      ];
      staticPasswords = [
        {
          email = "alex@${authDomain}";
          hash = "$2y$10$vTnuL0D2crbZIBOgE3TpK.vD9dzwDDt3c8YxGvTNSaYbvfJf7hWSi";
          username = "admin";
          userID = "1847de6f-4be1-4dac-8de0-acdf57b01952";
        }
      ];
      connectors = [
        {
          type = "ldap";
          id = "ldap";
          name = "LDAP";
          config = {
            host = "cloud.bat-boa.ts.net:3890";
            insecureNoSSL = true;
            insecureSkipVerify = true;
            bindDN = "uid=admin,ou=people,dc=rosenfeld,dc=one";
            bindPW = "$LLDAP_LDAP_USER_PASS";
            userSearch = {
              baseDN = "ou=people,dc=rosenfeld,dc=one";
              username = "uid";
              idAttr = "uid";
              emailAttr = "mail";
              nameAttr = "displayName";
              preferredUsernameAttr = "uid";
            };
            groupSearch = {
              baseDN = "ou=groups,dc=rosenfeld,dc=one";
              filter = "(objectClass=groupOfUniqueNames)";
              userMatchers = [
                {
                  userAttr = "DN";
                  groupAttr = "member";
                }
              ];
              nameAttr = "cn";
            };
          };
        }
      ];
    };
  };

  age.secrets.lldap-env.file = ../../secrets/lldap-env.age;
  age.secrets.lldap-env.mode = "444";

  services.lldap = {
    enable = true;
    settings = {
      http_url = "https://users.${mediaDomain}";
      ldap_user_email = "admin@${authDomain}";
      ldap_user_dn = "admin";
      ldap_base_dn = "dc=rosenfeld,dc=one";
    };
    environmentFile = config.age.secrets.lldap-env.path;
  };

  services.caddy = {
    enable = true;
  };

  services.searx = {
    enable = true;
    redisCreateLocally = true;
    settings = {
      server.port = ports.search;
      server.bind_address = "0.0.0.0";
      server.secret_key = "secret-indeed";
      server.method = "GET";
      ui.center_alignment = true;
      ui.infinite_scroll = true;
      ui.results_on_new_tab = true;
      ui.query_in_title = true;
      ui.default_locale = "en";
      search.autocomplete = "duckduckgo";
      search.favicon_resolver = "duckduckgo";
      engines = [
        {
          name = "bing";
          engine = "bing";
          disabled = true;
        }
        {
          name = "startpage";
          engine = "startpage";
          disabled = false;
        }
        {
          name = "duckduckgo";
          disabled = true;
        }
        {
          name = "qwant";
          disabled = true;
        }
      ];
    };
  };

  age.secrets.github-runner-token.file = ../../secrets/github-runner-token.age;

  # services.github-runners.cloud = {
  #   enable = false;
  #   extraLabels = ["nixos" "cloud" "aarch64"];
  #   tokenFile = config.age.secrets.github-runner-token.path;
  #   url = "https://github.com/arsfeld/nixos";
  # };

  age.secrets = {
    authelia-secrets = {
      file = ../../secrets/authelia-secrets.age;
      mode = "700";
      owner = "authelia-${autheliaConfig}";
    };
  };

  services.authelia.instances."${autheliaConfig}" = {
    enable = true;
    settings = {
      server = {
        address = "tcp://0.0.0.0:${toString ports.auth}";
      };
      authentication_backend = {
        ldap = {
          implementation = "custom";
          url = "ldap://127.0.0.1:3890";
          timeout = "5s";
          start_tls = "false";
          base_dn = "DC=rosenfeld,DC=one";
          username_attribute = "uid";
          additional_users_dn = "ou=people";
          users_filter = "(&({username_attribute}={input})(objectClass=person))";
          additional_groups_dn = "ou=groups";
          groups_filter = "(member={dn})";
          group_name_attribute = "cn";
          mail_attribute = "mail";
          display_name_attribute = "displayName";
          user = "uid=admin,ou=people,dc=rosenfeld,dc=one";
        };
      };
      access_control = {
        default_policy = "one_factor";
        rules = [
          {
            domain = "transmission.${mediaDomain}";
            policy = "bypass";
            resources = ["^/transmission/rpc$" "^/transmission/rpc/$"];
          }
          {
            domain = [
              "radarr.${mediaDomain}"
              "sonarr.${mediaDomain}"
              "prowlarr.${mediaDomain}"
              "lidarr.${mediaDomain}"
              "jackett.${mediaDomain}"
            ];
            policy = "bypass";
            resources = ["^/api/.*$" "^/api$"];
          }
          {
            domain = ["flaresolverr.${mediaDomain}"];
            policy = "bypass";
            resources = ["^/v1/.*$" "^/v1$"];
          }
          {
            domain = ["prowlarr.${mediaDomain}"];
            policy = "bypass";
            resources = ["^(/[0-9]+)?/api" "^(/[0-9]+)?/download"];
          }
          {
            domain = ["stash.${mediaDomain}"];
            policy = "bypass";
            resources = ["^/scene/([0-9]+)?/stream"];
          }
          {
            domain = ["yarr.${mediaDomain}"];
            policy = "bypass";
            resources = ["^/fever/.*$"];
          }
        ];
      };
      notifier = {
        disable_startup_check = false;
        filesystem = {
          filename = "/var/lib/authelia-${autheliaConfig}/notification.txt";
        };
      };
      session = {
        name = "authelia_session";
        expiration = "7d";
        inactivity = "45m";
        remember_me_duration = "1M";
        domain = "${mediaDomain}";
        redis.host = "/run/redis-authelia-${autheliaConfig}/redis.sock";
      };
      storage = {
        local = {
          path = "/var/lib/authelia-${autheliaConfig}/db.sqlite3";
        };
      };
    };
    settingsFiles = [config.age.secrets.authelia-secrets.path];
    secrets.manual = true;
  };

  services.redis.servers."authelia-${autheliaConfig}" = {
    enable = true;
    user = "authelia-${autheliaConfig}";
    port = 0;
    unixSocketPerm = 600;
  };

  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vault.${mediaDomain}";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = ports.vault;
      USE_SENDMAIL = true;
      SENDMAIL_COMMAND = "${pkgs.system-sendmail}/bin/sendmail";
      SMTP_FROM = "admin@rosenfeld.one";
    };
  };

  services.invidious = {
    enable = false;
    port = ports.invidious;
    domain = "invidious.${mediaDomain}";
    database.createLocally = true;
    settings = {
      https_only = true;
      db.user = "invidious";
    };
  };

  # For vscode
  nixpkgs.config.permittedInsecurePackages = [
    "nodejs-16.20.2"
  ];

  services.openvscode-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    withoutConnectionToken = true;
  };
}
