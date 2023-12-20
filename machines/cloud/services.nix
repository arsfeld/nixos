{config, ...}: {
  services.dex = {
    enable = true;
    settings = {
      # External url
      issuer = "https://rosenfeld.one";
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
          secret = "***REMOVED***";
        }
      ];
      staticPasswords = [
        {
          email = "alex@rosenfeld.one";
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
      http_url = "https://users.arsfeld.one";
      ldap_user_email = "admin@rosenfeld.one";
      ldap_user_dn = "admin";
      ldap_base_dn = "dc=rosenfeld,dc=one";
    };
    environmentFile = config.age.secrets.lldap-env.path;
  };

  services.caddy = {
    enable = true;
  };

  age.secrets.authelia-jwt.file = ../../secrets/authelia-jwt.age;
  age.secrets.authelia-jwt.mode = "444";

  age.secrets.authelia-storage-encryption-key.file = ../../secrets/authelia-storage-encryption-key.age;
  age.secrets.authelia-storage-encryption-key.mode = "444";

  services.authelia.instances."arsfeld.one" = {
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
          password = "***REMOVED***";
        };
      };
      access_control = {
        default_policy = "one_factor";
      };
      notifier = {
        disable_startup_check = false;
        filesystem = {
          filename = "/var/lib/authelia-arsfeld.one/notification.txt";
        };
      };
      storage = {
        local = {
          path = "/var/lib/authelia-arsfeld.one/db.sqlite3";
        };
      };
      session = {
        domain = "arsfeld.one";
      };
    };
    secrets = {
      jwtSecretFile = config.age.secrets.authelia-jwt.path;
      storageEncryptionKeyFile = config.age.secrets.authelia-storage-encryption-key.path;
    };
  };

  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://bitwarden.arsfeld.one";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
    };
  };

  services.invidious = {
    enable = true;
    port = 3939;
    domain = "invidious.arsfeld.one";
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
