{
  self,
  inputs,
}: {
  lib,
  pkgs,
  ...
}: let
  harmoniaPrivateKey = "harmonia-test-1:M2opSU4VcTBqLgNCjgAD2+LOXlJ5h9Sk9GH7Qxd7rQjscrJxUuMT09NlxO3rtsuS8IsCKT8x9pdQRcKExu5X3g==";
  harmoniaPublicKey = "harmonia-test-1:7HKycVLjE9PTZcTt67bLkvCLAik/MfaXUEXChMbuV94=";

  testArtifact = pkgs.runCommand "harmonia-test-artifact" {} ''
    mkdir -p $out
    echo "harmonia cache validation" > "$out/artifact.txt"
  '';
  testArtifactDrv = testArtifact.drvPath;

  buildCommand = "nix-store --realise ${testArtifactDrv} --add-root /nix/var/nix/gcroots/tests/harmonia-artifact --indirect";

  fetchCommand = "nix build --no-link ${testArtifact} --option builders \"\" --option fallback false --option substituters \"http://raider:5000\" --option trusted-public-keys \"${harmoniaPublicKey}\"";
in {
  name = "harmonia-cache";

  nodes = {
    raider = {
      config,
      pkgs,
      ...
    }: {
      imports = [inputs.harmonia.nixosModules.harmonia];

      networking.firewall.enable = false;
      networking.hostName = "raider";
      services.harmonia-dev.cache = {
        enable = true;
        signKeyPaths = ["/etc/harmonia/signing-key"];
        settings = {
          bind = "0.0.0.0:5000";
          enable_compression = true;
          priority = 60;
        };
      };

      systemd.services.harmonia-dev = {
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5s";
          StateDirectory = ["harmonia"];
        };
      };

      nix = {
        settings = {
          experimental-features = ["nix-command" "flakes"];
          keep-derivations = true;
          keep-outputs = true;
        };
        gc.options = lib.mkForce "--max-free 2G --min-free 512M";
      };

      environment.etc."harmonia/signing-key" = {
        text = harmoniaPrivateKey;
        mode = "0400";
      };

      systemd.tmpfiles.rules = [
        "d /nix/var/nix/gcroots/tests 0755 root root -"
      ];
    };

    client = {pkgs, ...}: {
      networking.firewall.enable = false;
      networking.hostName = "client";

      nix.settings = {
        experimental-features = ["nix-command" "flakes"];
        substituters = ["http://raider:5000"];
        trusted-public-keys = [harmoniaPublicKey];
        keep-derivations = true;
        keep-outputs = true;
      };
    };
  };

  testScript = ''
    start_all()

    raider.wait_for_unit("harmonia-dev.service")
    harmonia_key = "${harmoniaPublicKey}"

    # Seed the cache with a fixed-output store path
    raider.succeed("echo 'harmonia cache validation' > /tmp/harmonia-test-artifact")
    artifact_path = raider.succeed(
      "nix-store --add-fixed sha256 /tmp/harmonia-test-artifact"
    ).strip()
    raider.succeed(f"ln -sf {artifact_path} /nix/var/nix/gcroots/tests/harmonia-artifact")

    def fetch_from_cache():
      client.succeed(f"nix-store --delete {artifact_path} || true")
      result = client.succeed(
        f"nix copy --from http://raider:5000 --substituters http://raider:5000 --trusted-public-keys '{harmonia_key}' {artifact_path} 2>&1"
      )
      assert "copying path" in result, "expected to copy artifact from Harmonia"
      client.succeed(f"test -f {artifact_path}")
      return result

    fetch_from_cache()

    # Service restart should not break availability
    raider.succeed("systemctl restart harmonia-dev.service")
    raider.wait_for_unit("harmonia-dev.service")
    fetch_from_cache()

    # Validate persistence across garbage collection and a reboot
    raider.succeed("nix-collect-garbage -d")
    raider.reboot()
    raider.wait_for_unit("harmonia-dev.service")
    fetch_from_cache()
  '';
}
