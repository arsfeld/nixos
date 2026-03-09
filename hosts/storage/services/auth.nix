{
  self,
  config,
  pkgs,
  lib,
  ...
}: let
  domains = import "${self}/common/domains.nix";
  services = config.media.gateway.services;
  autheliaConfig = domains.mediaDomain;
  inherit (domains) mediaDomain authDomain;

  # Helper function to generate Authelia instance configuration
  mkAutheliaInstance = {
    domain,
    port,
  }: {
    enable = true;
    settings = {
      theme = "auto";
      server = {
        address = "tcp://0.0.0.0:${toString port}";
        endpoints.authz.forward-auth.implementation = lib.mkForce "ForwardAuth";
      };
      log = {
        level = "debug";
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
            domain = "transmission.${domain}";
            policy = "bypass";
            resources = ["^/transmission/rpc$" "^/transmission/rpc/$"];
          }
          {
            domain = [
              "radarr.${domain}"
              "sonarr.${domain}"
              "prowlarr.${domain}"
              "lidarr.${domain}"
              "jackett.${domain}"
            ];
            policy = "bypass";
            resources = ["^/api/.*$" "^/api$"];
          }
          {
            domain = ["flaresolverr.${domain}"];
            policy = "bypass";
            resources = ["^/v1/.*$" "^/v1$"];
          }
          {
            domain = ["prowlarr.${domain}"];
            policy = "bypass";
            resources = ["^(/[0-9]+)?/api" "^(/[0-9]+)?/download"];
          }
          {
            domain = ["stash.${domain}"];
            policy = "bypass";
            resources = ["^/scene/([0-9]+)?/stream"];
          }
          {
            domain = ["yarr.${domain}"];
            policy = "bypass";
            resources = ["^/fever/.*$"];
          }
        ];
      };
      notifier = {
        disable_startup_check = false;
        filesystem = {
          filename = "/var/lib/authelia-${domain}/notification.txt";
        };
      };
      session = {
        name = "authelia_session";
        expiration = "7d";
        inactivity = "45m";
        remember_me_duration = "1M";
        cookies = [
          {
            domain = domain;
            authelia_url = "https://auth.${domain}";
            default_redirection_url = "https://${domain}";
          }
        ];
        redis.host = "/run/redis-authelia-${domain}/redis.sock";
      };
      storage = {
        local = {
          path = "/var/lib/authelia-${domain}/db.sqlite3";
        };
      };
      identity_providers.oidc = {
        enforce_pkce = "public_clients_only";
        minimum_parameter_entropy = 8;
      };
    };
    settingsFiles = [config.age.secrets.authelia-secrets.path];
    secrets.manual = true;
  };
in {
  # Gateway entries for auth services
  media.gateway.services.auth = {
    port = 9091;
    exposeViaTailscale = true;
    settings.bypassAuth = true;
  };
  media.gateway.services.dex = {};
  media.gateway.services.users = {};

  age.secrets.dex-clients-tailscale-secret.file = "${self}/secrets/dex-clients-tailscale-secret.age";
  age.secrets.dex-clients-qui-secret.file = "${self}/secrets/dex-clients-qui-secret.age";
  age.secrets.lldap-env.file = "${self}/secrets/lldap-env.age";
  age.secrets.lldap-env.mode = "444";
  age.secrets.lldap-password.file = "${self}/secrets/lldap-password.age";
  age.secrets.lldap-password.mode = "400";
  age.secrets.authelia-secrets.file = "${self}/secrets/authelia-secrets.age";
  age.secrets.authelia-secrets.mode = "444";

  services.dex = {
    enable = true;
    environmentFile = config.age.secrets.lldap-env.path;
    settings = {
      issuer = "https://${authDomain}";
      storage = {
        type = "sqlite3";
        config.host = "/var/lib/dex/dex.db";
      };
      web = {
        http = "127.0.0.1:${toString services.dex.port}";
      };
      enablePasswordDB = true;
      staticClients = [
        {
          id = "tailscale";
          name = "Tailscale";
          redirectURIs = ["https://login.tailscale.com/a/oauth_response"];
          secretFile = config.age.secrets.dex-clients-tailscale-secret.path;
        }
        {
          id = "qui";
          name = "Qui";
          redirectURIs = ["https://qui.arsfeld.one/api/auth/oidc/callback"];
          secretFile = config.age.secrets.dex-clients-qui-secret.path;
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
            host = "127.0.0.1:3890";
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

  services.lldap = {
    enable = true;
    settings = {
      http_url = "https://users.${mediaDomain}";
      ldap_user_email = "admin@${authDomain}";
      ldap_user_dn = "admin";
      ldap_base_dn = "dc=rosenfeld,dc=one";
      http_port = services.users.port;
    };
    environmentFile = config.age.secrets.lldap-env.path;
    environment.LLDAP_LDAP_USER_PASS_FILE = config.age.secrets.lldap-password.path;
  };

  # Authelia instance for arsfeld.one domain
  services.authelia.instances."${autheliaConfig}" = mkAutheliaInstance {
    domain = mediaDomain;
    port = 9091;
  };

  services.redis.servers."authelia-${autheliaConfig}" = {
    enable = true;
    user = "authelia-${autheliaConfig}";
    port = 0;
    unixSocketPerm = 600;
  };
}
