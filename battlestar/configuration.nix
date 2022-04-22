{...}: {
  imports = [
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./services.nix
    ./overlays.nix
  ];
  boot.cleanTmpDir = true;

  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  # fileSystems."/boot" = { device = "$esp"; fsType = "vfat"; };
  zramSwap.enable = true;
  networking.hostName = "battlestar";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com"
  ];
}
