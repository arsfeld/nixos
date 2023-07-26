{ ... }: {
  imports = [
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
  ];

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.hostName = "cloud";
  networking.domain = "penguin-gecko.ts.net";
  services.openssh.enable = true;

  services.tailscale.enable = true;

  users.users.arosenfeld = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''
    ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''
  ];
}