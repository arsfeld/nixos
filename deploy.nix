{
  self,
  inputs,
}: {
  sshUser = "root";
  autoRollback = false;
  magicRollback = false;
  nodes = {
    storage = {
      hostname = "storage";
      profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.storage;
    };
    raider = {
      hostname = "raider-nixos";
      fastConnection = true;
      profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.raider;
    };
    cloud = {
      hostname = "cloud";
      remoteBuild = true;
      profiles.system.path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.cloud;
    };
    cloud-br = {
      hostname = "cloud-br";
      profiles.system.path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.cloud-br;
    };
    r2s = {
      hostname = "192.168.1.10";
      fastConnection = true;
      profiles.system.path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.r2s;
    };
    raspi3 = {
      hostname = "raspi3";
      fastConnection = true;
      profiles.system.path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.raspi3;
    };
    core = {
      hostname = "core";
      profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.core;
    };
    g14 = {
      hostname = "g14";
      fastConnection = true;
      profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.g14;
    };
    hpe = {
      hostname = "hpe";
      fastConnection = true;
      profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.hpe;
    };
  };
}
