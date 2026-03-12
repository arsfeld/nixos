{
  modulesPath,
  self,
  config,
  inputs,
  ...
}: {
  imports = [
    inputs.eh5.nixosModules.fake-hwclock
    ./hardware-configuration.nix
    (import ./networking.nix {
      internalInterface = "enu1"; # or w/e ethernet interface you want to connect your raspberry pi to
      externalInterface = "end0"; # or w/e interface you get your internet connection to your pc
    })
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  nixpkgs.overlays = [
    inputs.eh5.overlays.default
  ];

  networking.hostName = "r2s";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.firewall.enable = false;

  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";

  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
