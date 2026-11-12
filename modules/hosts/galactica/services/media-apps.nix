# Media applications: Ohdio, Qui, Mydia
{
  configurations.nixos.galactica.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    vars = config.media.config;
    pia = config.constellation.pia;
    mydiaVpnEnv = "/run/mydia/vpn.env";
    # podman's default bridge gateway, as seen from the mydia container.
    mydiaGarageProxy = "10.88.0.1:3900";
  in {
    config = lib.mkMerge [
      {
        sops.secrets.ohdio-env.mode = "0444";
        sops.secrets.qui-oidc-env.mode = "0444";
        sops.secrets.mydia-env.mode = "0444";

        # Settings for the sideloaded Assistant plugin. Mydia applies them at
        # startup (and saves them to its database); the key is the same
        # OpenRouter key plab uses. Users can switch models on the page.
        sops.templates.mydia-assistant-env.content = ''
          PLUGIN_0_SLUG=assistant-openai
          PLUGIN_0_SETTINGS=${builtins.toJSON {
            provider = "OpenRouter";
            api_key = config.sops.placeholder.openrouter-api-key;
            model = "deepseek/deepseek-v4.1-flash";
            model_choice = "Users can choose";
          }}
        '';
        # The env file path never changes, so a new model or key would not
        # restart the container on its own.
        sops.templates.mydia-assistant-env.restartUnits = ["${config.virtualisation.oci-containers.backend}-mydia.service"];

        # Credentials for the garage storage backend (garage.nix).
        sops.templates.mydia-s3-env.content = ''
          STORAGE_BACKEND_1_ACCESS_KEY_ID=${config.sops.placeholder.garage-mydia-access-key-id}
          STORAGE_BACKEND_1_SECRET_ACCESS_KEY=${config.sops.placeholder.garage-mydia-secret-access-key}
        '';
        sops.templates.mydia-s3-env.restartUnits = ["${config.virtualisation.oci-containers.backend}-mydia.service"];
      }

      {
        media.services.ohdio = {
          # Hardened run matched control behaviour; entrypoint lines read.
          # CHOWN: 'chown -R ohdio:ohdio /config /app'.
          # DAC_OVERRIDE: useradd/usermod/groupmod edit /etc files, writes /config owned by media.
          # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
          # SETUID, SETGID: 'exec gosu ohdio "$@"' (hardened exit 10 without them).
          container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
          port = 4000;
          image = "ghcr.io/arsfeld/ohdio:latest";
          container = {
            environment = {
              PHX_HOST = "ohdio.arsfeld.one";
              PORT = "4000";
              MIX_ENV = "prod";
              DATABASE_PATH = "/config/db/ohdio_prod.db";
              STORAGE_PATH = "/config/downloads";
              MAX_CONCURRENT_DOWNLOADS = "3";
              CHECK_ORIGIN = "https://ohdio.arsfeld.one,https://ohdio.bat-boa.ts.net";
            };
            environmentFiles = [
              config.sops.secrets.ohdio-env.path
            ];
          };
          bypassAuth = true;
        };
      }

      {
        media.services.qui = {
          # Hardened run matched control behaviour; entrypoint lines read.
          # CHOWN: entrypoint chowns anything in /config not owned by PUID:PGID.
          # DAC_OVERRIDE: adduser edits /etc, /config owned by media.
          # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
          # SETUID, SETGID: su-exec to PUID/PGID ('su-exec: setgroups(): Operation not permitted' seen).
          container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
          port = 7476;
          image = "ghcr.io/autobrr/qui";
          container = {
            environment = {
              QUI__HOST = "0.0.0.0";
              QUI__PORT = "7476";
              QUI__OIDC_ENABLED = "true";
              QUI__OIDC_ISSUER = "https://auth.arsfeld.one";
              QUI__OIDC_CLIENT_ID = "qui";
              QUI__OIDC_REDIRECT_URL = "https://qui.arsfeld.one/api/auth/oidc/callback";
              QUI__OIDC_DISABLE_BUILT_IN_LOGIN = "false";
            };
            environmentFiles = [
              config.sops.secrets.qui-oidc-env.path
            ];
            extraOptions = [
              "--no-healthcheck"
            ];
          };
          bypassAuth = true;
        };
      }

      {
        media.services.mydia = {
          # Not probe-verified (the probe could not run it without secrets/DB); caps come from the image's entrypoint. Entrypoint saw: groupmod/usermod/adduser to set PUID/PGID, and a chown of app dirs (never /media).
          # CHOWN: entrypoint chowns application directories.
          # DAC_OVERRIDE: usermod/groupmod edit /etc files and dirs owned by media.
          # FOWNER: precautionary alongside DAC_OVERRIDE.
          # SETUID, SETGID: precautionary (the entrypoint changes the mydia user to PUID/PGID, then ends with `exec su-exec mydia`).
          # NET_ADMIN, NET_RAW: the built-in VPN's gluetun builds the tunnel, its iptables rules and policy routing.
          # NET_BIND_SERVICE: gluetun's DNS server listens on 127.0.0.1:53.
          # KILL: the entrypoint's root loop stops and restarts gluetun.
          #
          # Hardening is applied by hand below because the module's version adds
          # no-new-privileges, and the built-in torrent engine is a setgid binary
          # (group mydia-torrent, which the VPN's split tunnel keys on).
          container.hardening.enable = false;
          port = 4000;
          image = "ghcr.io/getmydia/mydia:master";
          watchImage = true;
          container = {
            exposePort = 4000;
            mediaVolumes = true;
            # Its own network namespace, not the host's: the built-in VPN's
            # gluetun installs routes and iptables rules in whatever namespace
            # it runs in, and its control (127.0.0.1:8000) and health (9999)
            # servers collide with rest-server and stash on the host. It sits
            # on podman's default bridge (rootful podman has no pasta), so
            # host services are addressed as host.containers.internal, and
            # garage, which listens on loopback only, through the proxy below.
            network = null;
            devices = ["/dev/dri:/dev/dri" "/dev/net/tun:/dev/net/tun"];
            volumes = [
              # gluetun's own lookups (health check, PIA API) are tunneled,
              # and its kill switch lets tunneled traffic leave only on lo or
              # tun0, so podman's bridge resolver (10.88.0.1) is blocked for
              # them. A public resolver is reached either way: through the
              # tunnel for gluetun, directly for the rest of mydia. (--dns
              # only sets aardvark's upstream; resolv.conf stays 10.88.0.1.)
              "${pkgs.writeText "mydia-resolv.conf" ''
                nameserver 1.1.1.1
                nameserver 9.9.9.9
              ''}:/etc/resolv.conf:ro"
            ];
            extraOptions = [
              "--cap-drop=ALL"
              "--cap-add=CHOWN"
              "--cap-add=DAC_OVERRIDE"
              "--cap-add=FOWNER"
              "--cap-add=SETUID"
              "--cap-add=SETGID"
              "--cap-add=KILL"
              "--cap-add=NET_ADMIN"
              "--cap-add=NET_RAW"
              "--cap-add=NET_BIND_SERVICE"
              # Reaps an OpenVPN child left behind when gluetun restarts.
              "--init"
              "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
            ];
            environment = {
              PHX_HOST = "mydia.arsfeld.one";
              PORT = "4000";
              TV_PATH = "/media/Series";
              MOVIES_PATH = "/media/Movies";
              OIDC_REDIRECT_URI = "https://mydia.arsfeld.one/auth/oidc/callback";
              FLARESOLVERR_ENABLED = "true";
              FLARESOLVERR_URL = "http://host.containers.internal:8191";
              # The indexers are set in the mydia-env secret with localhost
              # URLs, which the bridge no longer reaches; these override them.
              INDEXER_1_BASE_URL = "http://host.containers.internal:9696";
              INDEXER_2_BASE_URL = "http://host.containers.internal:3333/torznab/";
              ENABLE_REMOTE_ACCESS = "true";
              # Built-in torrent client (rqbit), tunneled through PIA by the
              # image's gluetun. OpenVPN, since gluetun has no PIA WireGuard.
              # The credentials come from the env file written in preStart.
              MYDIA_TORRENT_ENABLED = "true";
              MYDIA_TORRENT_DOWNLOAD_PATH = "${vars.storageDir}/media/Downloads/mydia";
              MYDIA_VPN_SERVICE_PROVIDER = "pia";
              MYDIA_VPN_VPN_TYPE = "openvpn";
              # A port-forwarding region, near constellation.pia's "ca".
              MYDIA_VPN_SERVER_REGIONS = "CA Montreal";
              # gluetun's bundled PIA list (2026-04) still has Montreal
              # servers PIA has retired (212.56.49.x, which never answer);
              # these are in PIA's live list as of 2026-11.
              MYDIA_VPN_SERVER_NAMES = "montreal428,montreal430,montreal431";
              MYDIA_VPN_VPN_PORT_FORWARDING = "on";
              # The PIA-confined Transmission (galactica's transmission-vpn.nix),
              # kept behind the built-in client (priority 10) so grabs already
              # in it finish there. The bridge sends this address out through
              # the host, where the namespace's DNAT rules apply.
              DOWNLOAD_CLIENT_1_NAME = "transmission";
              DOWNLOAD_CLIENT_1_TYPE = "transmission";
              DOWNLOAD_CLIENT_1_ENABLED = "true";
              DOWNLOAD_CLIENT_1_PRIORITY = "20";
              DOWNLOAD_CLIENT_1_HOST = pia.namespaceAddress;
              DOWNLOAD_CLIENT_1_PORT = "9091";
              DOWNLOAD_CLIENT_1_USE_SSL = "false";
              DOWNLOAD_CLIENT_1_AUTO_REMOVE = "true";
              DOWNLOAD_CLIENT_1_REMOVE_COMPLETED = "true";
              DOWNLOAD_CLIENT_1_DOWNLOAD_DIRECTORY = "${vars.storageDir}/media/Downloads";
              # An extra movies library in S3, served by the local Garage
              # (garage.nix), to test mydia's S3 storage end to end.
              STORAGE_BACKEND_1_NAME = "garage";
              STORAGE_BACKEND_1_ENDPOINT = "http://${mydiaGarageProxy}";
              STORAGE_BACKEND_1_REGION = "garage";
              STORAGE_BACKEND_1_BUCKET = "mydia";
              STORAGE_BACKEND_1_PATH_STYLE = "true";
              LIBRARY_PATH_1_PATH = "s3://garage/movies";
              LIBRARY_PATH_1_NAME = "S3 Movies (test)";
              LIBRARY_PATH_1_TYPE = "movies";
            };
            environmentFiles = [
              config.sops.secrets.mydia-env.path
              config.sops.templates.mydia-assistant-env.path
              config.sops.templates.mydia-s3-env.path
              mydiaVpnEnv
            ];
          };
          bypassAuth = true;
        };

        # The PIA login, renamed to the variables mydia's VPN reads. The
        # shared pia-credentials secret uses PIA_USER/PIA_PASS.
        systemd.services."${config.virtualisation.oci-containers.backend}-mydia".preStart = lib.mkBefore ''
          install -d -m 0700 /run/mydia
          umask 077
          ${pkgs.gnused}/bin/sed -n \
            -e 's/^PIA_USER=/MYDIA_VPN_OPENVPN_USER=/p' \
            -e 's/^PIA_PASS=/MYDIA_VPN_OPENVPN_PASSWORD=/p' \
            ${pia.credentialsFile} > ${mydiaVpnEnv}
        '';
        systemd.tmpfiles.rules = [
          "d ${vars.storageDir}/media/Downloads/mydia 0775 ${vars.user} ${vars.group} -"
        ];

        # Garage's S3 API listens on loopback only; expose it on podman's
        # bridge gateway, where the mydia container can reach it and the LAN
        # cannot. FreeBind lets the socket come up before podman0 exists.
        systemd.sockets.mydia-garage-proxy = {
          wantedBy = ["sockets.target"];
          socketConfig = {
            ListenStream = mydiaGarageProxy;
            FreeBind = true;
          };
        };
        systemd.services.mydia-garage-proxy = {
          requires = ["mydia-garage-proxy.socket"];
          after = ["mydia-garage-proxy.socket"];
          serviceConfig = {
            ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:3900";
            DynamicUser = true;
            PrivateNetwork = false;
          };
        };
      }
    ];
  };
}
