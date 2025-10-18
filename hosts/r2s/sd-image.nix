# save as sd-image.nix somewhere
{inputs, ...}: {
  imports = [
    <nixpkgs/nixos/modules/installer/sd-card/sd-image-aarch64.nix>
    inputs.eh5.nixosModules.fake-hwclock
    ./hardware-configuration.nix
  ];

  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };

  networking.useDHCP = true;

  # put your own configuration here, for example ssh keys:
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
