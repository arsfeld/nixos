{
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
  ];

  ec2.hvm = true;
  ec2.efi = true;

  networking.hostName = "libran";

  services.syncthing = {
    enable = false;
    overrideDevices = true;
    overrideFolders = true;
    guiAddress = "0.0.0.0:8384";
    user = "media";
    group = "media";
    devices = {
      # "picon" = { id = "LLHMFJQ-NRACEUQ-5BK7NHF-XORU7H6-7PEBGUJ-AO2C3L6-LVUD4CJ-YFJHDAS"; };
      "striker" = {id = "MKCL44W-QVJTNJ7-HVNG34K-ORECL5N-IUXBE47-2RJIZDE-YVE2RAP-5ABUKQP";};
    };
    folders = {
      "data" = {
        id = "data";
        path = "/var/data";
        devices = ["striker"];
      };
    };
  };
}
