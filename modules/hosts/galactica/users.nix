{
  configurations.nixos.galactica.module = {
    config,
    pkgs,
    lib,
    ...
  }: {
    users.users.camille = {
      uid = 1001;
      isNormalUser = true;
      description = "Camille Paradis-Gaudet";
      group = "camille";
      home = "/home/camille";
      extraGroups = ["media" "users"];
    };

    users.groups.camille.gid = 1001;
  };
}
