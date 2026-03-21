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

  constellation.sops.enable = true;

  networking.hostName = "r2s";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.firewall.enable = false;

  sops.secrets.tailscale-key.sopsFile = config.constellation.sops.commonSopsFile;

  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
