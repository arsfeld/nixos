{
  config,
  pkgs,
  lib,
  ...
}: {
  options = with lib;
  with types; {
    vars = mkOption {type = attrsOf str;};
  };
  config = {
    vars = {
      configDir = "/var/data";
      dataDir = "/mnt/data";
      puid = "5000";
      pgid = "5000";
      user = "media";
      group = "media";
      tz = "America/Toronto";
      email = "arsfeld@gmail.com";
      domain = "arsfeld.one";
    };
  };
}
