{
  config,
  self,
  ...
}: let
  ports = (import "${self}/common/services.nix" {}).ports;
in {
  virtualisation.oci-containers.containers = {
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

    metube = {
      image = "ghcr.io/alexta69/metube";
      volumes = ["/var/lib/metube:/downloads"];
      ports = ["${toString ports.metube}:8081"];
    };
  };
}
