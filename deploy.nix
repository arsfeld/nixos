{
  self,
  inputs,
}: let
  mkDeploy = {
    hostname ? null,
    system ? "x86_64-linux",
    fastConnection ? false,
    remoteBuild ? false,
  }: {
    inherit hostname fastConnection remoteBuild;
    profiles.system.path = inputs.deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${hostname};
  };
in {
  sshUser = "root";
  autoRollback = false;
  magicRollback = false;
  nodes = {
    storage = mkDeploy {
      hostname = "storage";
    };
    raider = mkDeploy {
      hostname = "raider-nixos";
      fastConnection = true;
    };
    cloud = mkDeploy {
      hostname = "cloud";
      system = "aarch64-linux";
      remoteBuild = true;
    };
    cloud-br = mkDeploy {
      hostname = "cloud-br";
      system = "aarch64-linux";
    };
    r2s = mkDeploy {
      hostname = "192.168.1.10";
      system = "aarch64-linux";
      fastConnection = true;
    };
    raspi3 = mkDeploy {
      hostname = "raspi3";
      system = "aarch64-linux";
      fastConnection = true;
    };
    core = mkDeploy {
      hostname = "core";
    };
    g14 = mkDeploy {
      hostname = "g14";
      fastConnection = true;
    };
    hpe = mkDeploy {
      hostname = "hpe";
      fastConnection = true;
    };
  };
}
