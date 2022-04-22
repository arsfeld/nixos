{...}: let
  sda = "ata-HGST_HUS724020ALA640_PN2134P5G7K3KX";
  sdb = "ata-HGST_HUS724020ALA640_PN2134P6HWSS0X";
  sdc = "ata-HGST_HUS724020ALA640_PN2134P6H5MAHP";
  sdd = "ata-HGST_HUS724020ALA640_PN1186P2G112YH";
in {
  imports = [
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./services.nix
    ./overlays.nix
    ./mail.nix
  ];

  boot.loader.grub = {
    efiSupport = true;
    device = "nodev";
  };

  fileSystems."/boot".options = ["nofail"];
  fileSystems."/boot-2".options = ["nofail"];
  fileSystems."/boot-3".options = ["nofail"];
  fileSystems."/boot-4".options = ["nofail"];

  boot.loader.grub.mirroredBoots = [
    {
      path = "/boot";
      devices = ["/dev/disk/by-id/${sda}"];
    }
    {
      path = "/boot-2";
      devices = ["/dev/disk/by-id/${sdb}"];
    }
    {
      path = "/boot-3";
      devices = ["/dev/disk/by-id/${sdc}"];
    }
    {
      path = "/boot-4";
      devices = ["/dev/disk/by-id/${sdd}"];
    }
  ];

  services.zfs.autoScrub.enable = true;
  services.smartd.enable = true;
  services.smartd.notifications.mail.enable = true;
  services.smartd.notifications.test = true;
  services.sshguard.enable = true;
  zramSwap.enable = true;
  networking.hostName = "battlestar";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com"
  ];
}
