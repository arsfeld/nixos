{
  self,
  inputs,
  ...
}: {
  flake = {
    packages.aarch64-linux = {
      raspi3 = inputs.nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules =
          self.lib.baseModules
          ++ [
            ../hosts/raspi3/configuration.nix
          ];
        specialArgs = {inherit self inputs;};
        format = "sd-aarch64";
      };
      octopi = inputs.nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules =
          self.lib.baseModules
          ++ [
            ../hosts/octopi/configuration.nix
          ];
        specialArgs = {inherit self inputs;};
        format = "sd-aarch64";
      };
    };

    # Testing configurations and packages
    packages.x86_64-linux = {
      # Add ARM images from above to ensure we have all the entries
      inherit (self.packages.aarch64-linux) raspi3 octopi;

      # Router QEMU test
      router-test =
        inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ../tests/router-qemu-test.nix
        {};

      # Custom kexec image with Tailscale for nixos-anywhere
      kexec-tailscale = inputs.nixos-generators.nixosGenerate {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        modules = [../kexec-tailscale.nix];
        format = "kexec-bundle";
      };
    };
  };
}
