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
      hostname = "storage.bat-boa.ts.net";
    };
    raider = mkDeploy {
      hostname = "raider-nixos.bat-boa.ts.net";
      fastConnection = true;
    };
    cloud = mkDeploy {
      hostname = "cloud.bat-boa.ts.net";
      system = "aarch64-linux";
      remoteBuild = true;
    };
    cloud-br = mkDeploy {
      hostname = "cloud-br.bat-boa.ts.net";
      system = "aarch64-linux";
    };
    r2s = mkDeploy {
      hostname = "r2s.bat-boa.ts.net";
      system = "aarch64-linux";
      fastConnection = true;
    };
    raspi3 = mkDeploy {
      hostname = "raspi3.bat-boa.ts.net";
      system = "aarch64-linux";
      fastConnection = true;
    };
    core = mkDeploy {
      hostname = "core.bat-boa.ts.net";
    };
    g14 = mkDeploy {
      hostname = "g14.bat-boa.ts.net";
      fastConnection = true;
    };
    hpe = mkDeploy {
      hostname = "hpe.bat-boa.ts.net";
      fastConnection = true;
    };
  };
}
