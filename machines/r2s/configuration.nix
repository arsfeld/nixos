# save as sd-image.nix somewhere
{...}: {
  imports = [
    <nixpkgs/nixos/modules/installer/sd-card/sd-image-aarch64.nix>
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./hardware.nix
    (import ./networking.nix {
      internalInterface = "eth1"; # or w/e ethernet interface you want to connect your raspberry pi to
      externalInterface = "eth0"; # or w/e interface you get your internet connection to your pc
    })
  ];

  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };

  #networking.useDHCP = true;
  networking.hostName = "r2s";

  services.adguardhome = {
    enable = true;
  };

  # put your own configuration here, for example ssh keys:
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
