args @ {pkgs, ...}: let
  sda = "ata-HGST_HUS724020ALA640_PN2134P5G7K3KX";
  sdb = "ata-HGST_HUS724020ALA640_PN2134P6HWSS0X";
  sdc = "ata-HGST_HUS724020ALA640_PN2134P6H5MAHP";
  sdd = "ata-HGST_HUS724020ALA640_PN1186P2G112YH";
in {
  imports = [
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ../../common/mail.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./web.nix
    ./services.nix
    ./overlays.nix
    ./rclone-mount.nix
    (
      import ../../common/backup.nix (
        args
        // {repo = "lm036010@lm036010.repo.borgbase.com:repo";}
      )
    )
  ];

  boot.loader.systemd-boot.enable = true;

  boot.loader.grub = {
    enable = false;
    efiSupport = true;
    device = "nodev";
    efiInstallAsRemovable = true;
  };

  fileSystems."/boot".options = ["nofail"];
  # fileSystems."/boot-2".options = ["nofail"];
  # fileSystems."/boot-3".options = ["nofail"];
  # fileSystems."/boot-4".options = ["nofail"];

  # boot.loader.grub.mirroredBoots = [
  #   {
  #     path = "/boot";
  #     devices = ["/dev/disk/by-id/${sda}"];
  #   }
  #   {
  #     path = "/boot-2";
  #     devices = ["/dev/disk/by-id/${sdb}"];
  #   }
  #   {
  #     path = "/boot-3";
  #     devices = ["/dev/disk/by-id/${sdc}"];
  #   }
  #   {
  #     path = "/boot-4";
  #     devices = ["/dev/disk/by-id/${sdd}"];
  #   }
  # ];

  users.users.borg = {
    isSystemUser = true;
    home = "/mnt/data/backups/borg";
    group = "borg";
    createHome = true;
    useDefaultShell = true;
    openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVa2dy7NNkWEAyRYLP8uW3WIOQVrEsfmfPr1YDZ2DTL root@storage"];
  };
  users.groups.borg = {};

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
