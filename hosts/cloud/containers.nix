{
  config,
  self,
  ...
}: let
  ports = (import "${self}/common/services.nix" {}).ports;
in {
  age.secrets."gluetun-pia".file = "${self}/secrets/gluetun-pia.age";

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    ghost = {
      image = "ghost:5";
      volumes = ["/var/lib/ghost/content:/var/lib/ghost/content"];
      environment = {
        url = "https://blog.arsfeld.dev";
        database__client = "sqlite3";
        database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
        database__useNullAsDefault = "true";
        # mail__transport = "SMTP";
        # mail__host = "wednesday.mxrouting.net";
        # mail__port = "587";
        # mail__secure = "true";
        # mail__auth__user = "admin@arsfeld.one";
        # mail__auth__pass = builtins.readFile config.age.secrets.smtp_password.path;
      };
      ports = ["${toString ports.ghost}:2368"];
    };

    whoogle = {
      image = "benbusby/whoogle-search:latest";
      ports = ["${toString ports.whoogle}:5000"];
    };

    # gluetun = {
    #   image = "qmcgaw/gluetun";
    #   environment = {
    #     SERVER_REGIONS = "Brazil";
    #   };
    #   environmentFiles = [
    #     config.age.secrets.gluetun-pia.path
    #   ];
    #   volumes = [
    #     "/var/lib/gluetun:/gluetun"
    #   ];
    #   extraOptions = [
    #     "--cap-add"
    #     "NET_ADMIN"
    #   ];
    # };

    # ts-gluetun = {
    #   image = "ghcr.io/tailscale/tailscale:latest";
    #   environment = {
    #     TS_HOSTNAME = "pia-br";
    #     TS_EXTRA_ARGS = "--advertise-tags=tag:exit --advertise-exit-node";
    #     TS_STATE_DIR = "/var/lib/tailscale";
    #   };
    #   volumes = [
    #     "/var/lib/ts-gluetun:/var/lib/tailscale"
    #   ];
    #   extraOptions = [
    #     "--network=container:gluetun"
    #   ];
    # };

    metube = {
      image = "ghcr.io/alexta69/metube";
      volumes = ["/var/lib/metube:/downloads"];
      ports = ["${toString ports.metube}:8081"];
    };
  };
}
