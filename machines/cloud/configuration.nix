{config, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../../common/acme.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ../../common/sites/arsfeld.one.nix
    ../../common/sites/rosenfeld.one.nix
    ../../common/sites/rosenfeld.blog.nix
    ../../common/sites/arsfeld.dev.nix
    ./services.nix
    ./containers.nix
  ];

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.hostName = "cloud";
  networking.firewall.enable = false;
  # This should be overriden by tailscale at some point
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];

  services.atticd = {
    enable = true;

    # Replace with absolute path to your credentials file
    credentialsFile = "/etc/atticd.env";

    settings = {
      listen = "[::]:8080";
      chunking = {
        # The minimum NAR size to trigger chunking
        #
        # If 0, chunking is disabled entirely for newly-uploaded NARs.
        # If 1, all NARs are chunked.
        nar-size-threshold = 64 * 1024; # 64 KiB

        # The preferred minimum size of a chunk, in bytes
        min-size = 16 * 1024; # 16 KiB

        # The preferred average size of a chunk, in bytes
        avg-size = 64 * 1024; # 64 KiB

        # The preferred maximum size of a chunk, in bytes
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };
}
