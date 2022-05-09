{
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  users.users = {
    arosenfeld = {
      home = lib.mkForce "/mnt/data/homes/arosenfeld";
    };
    camille = {
      uid = 1001;
      isNormalUser = true;
      description = "Camille Paradis-Gaudet";
      group = "camille";
      home = "/mnt/data/homes/camille";
      extraGroups = ["media" "users"];
    };
  };

  users.groups.arosenfeld.gid = 1000;
  users.groups.camille.gid = 1001;
}
