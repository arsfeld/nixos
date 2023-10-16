{
  lib,
  config,
  pkgs,
  ...
}: {
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
      ports = ["2368:2368"];
    };

    yarr = {
      image = "arsfeld/yarr:c76ff26bd6dff6137317da2fe912bc44950eb17a";
      volumes = ["/var/lib/yarr:/data"];
      ports = ["7070:7070"];
      environment = {
        "YARR_AUTH" = "admin:***REMOVED***";
      };
    };
  };
}
