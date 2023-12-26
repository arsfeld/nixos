{config, ...}: let
  mediaDomain = "arsfeld.one";
  authDomain = "rosenfeld.one";
  autheliaConfig = "arsfeld.one";
in {
  age.secrets.dex-clients-tailscale-secret.file = ../../secrets/dex-clients-tailscale-secret.age;

  services.dex = {
    enable = true;
    settings = {
      # External url
      issuer = "https://${authDomain}";
      storage = {
        type = "sqlite3";
        config.host = "/var/lib/dex/dex.db";
      };
      web = {
        http = "127.0.0.1:5556";
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

  age.secrets = {
    authelia-jwt = {
      file = ../../secrets/authelia-jwt.age;
      mode = "700";
      owner = "authelia-${autheliaConfig}";
    };

    authelia-storage-encryption-key = {
      file = ../../secrets/authelia-storage-encryption-key.age;
      mode = "700";
      owner = "authelia-${autheliaConfig}";
    };

    authelia-session-secret = {
      file = ../../secrets/authelia-session-secret.age;
      mode = "700";
      owner = "authelia-${autheliaConfig}";
    };

    authelia-ldap-password = {
      file = ../../secrets/authelia-ldap-password.age;
      mode = "700";
      owner = "authelia-${autheliaConfig}";
    };
  };

  services.authelia.instances."${autheliaConfig}" = {
    enable = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 9099;
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
            domain = ["radarr.${mediaDomain}" "sonarr.${mediaDomain}" "prowlarr.${mediaDomain}" "jackett.${mediaDomain}"];
            policy = "bypass";
            resources = ["^/api/.*$" "^/api$"];
          }
          {
            domain = ["prowlarr.${mediaDomain}"];
            policy = "bypass";
            resources = ["^(/[0-9]+)?/api" "^(/[0-9]+)?/download"];
          }
          {
            domain = ["yarr.${mediaDomain}"];
            policy = "bypass";
            resources = ["^fever/.*$"];
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
    secrets = {
      jwtSecretFile = config.age.secrets.authelia-jwt.path;
      storageEncryptionKeyFile = config.age.secrets.authelia-storage-encryption-key.path;
      sessionSecretFile = config.age.secrets.authelia-session-secret.path;
    };
    environmentVariables = {
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.age.secrets.authelia-ldap-password.path;
    };
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
      DOMAIN = "https://bitwarden.${mediaDomain}";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
    };
  };

  services.invidious = {
    enable = true;
    port = 3939;
    domain = "invidious.${mediaDomain}";
    database.createLocally = true;
    settings = {
      https_only = true;
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
