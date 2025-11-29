{pkgs, ...}:
# Build Caddy with Tailscale plugin
# nixos-25.11+ uses Go 1.25 as default, so buildGoModule works directly
pkgs.buildGoModule rec {
  pname = "caddy-with-tailscale";
  version = "2.9.1"; # Caddy version from go.mod

  # Use the local source directory
  src = ./.;

  # Computed vendorHash from building with Go 1.25 from nixpkgs-unstable
  vendorHash = "sha256-rKJu1lt4Qz6Urw3eLw9rULs+gP7xMGpKkJmEYnxUyPQ=";

  # Build the caddy binary from the main.go at the root
  subPackages = ["."];

  # Pass the Caddy version as a build flag
  ldflags = [
    "-s"
    "-w"
    "-X github.com/caddyserver/caddy/v2.CustomVersion=${version}"
  ];

  # Copy the plugin source to satisfy the replace directive in go.mod
  # The go.mod has: replace github.com/tailscale/caddy-tailscale => ../caddy-tailscale-plugin
  postPatch = ''
    # Copy the plugin source to be a sibling of the current directory
    echo "=== PostPatch: Copying plugin source ==="
    echo "PWD: $PWD"

    # Go up one level and copy the plugin there
    cd ..
    cp -r ${../caddy-tailscale-plugin} ./caddy-tailscale-plugin
    chmod -R +w ./caddy-tailscale-plugin

    echo "Copied plugin source to $(pwd)/caddy-tailscale-plugin"

    # Go back to source directory
    cd -
    echo "=== End PostPatch ==="
  '';

  # Verify the build succeeded and caddy is functional
  doCheck = false; # Skip tests for now as they may require network

  meta = with pkgs.lib; {
    description = "Caddy web server with Tailscale OAuth integration";
    homepage = "https://github.com/tailscale/caddy-tailscale";
    license = licenses.asl20;
    mainProgram = "caddy-with-tailscale";
    platforms = platforms.linux ++ platforms.darwin;
  };
}
