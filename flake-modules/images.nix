{
  self,
  inputs,
  ...
}: {
  flake = {
    packages.aarch64-linux = {
      raspi3 = self.nixosConfigurations.raspi3.config.system.build.sdImage;
      octopi = self.nixosConfigurations.octopi.config.system.build.sdImage;
      r2s = self.nixosConfigurations.r2s.config.system.build.sdImage;
    };

    # Testing configurations and packages
    packages.x86_64-linux = {
      # Add ARM images from above to ensure we have all the entries
      inherit (self.packages.aarch64-linux) raspi3 octopi r2s;

      # Router QEMU test
      router-test =
        inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ../tests/router-qemu-test.nix
        {};

      # Custom kexec image with Tailscale for nixos-anywhere
      kexec-tailscale =
        (inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [../kexec.nix];
        }).config.system.build.kexecTarball;
    };
  };
}
