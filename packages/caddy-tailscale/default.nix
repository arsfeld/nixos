{
  pkgs,
  lib,
  ...
}: let
  # Build the OAuth-supporting fork of caddy-tailscale plugin
  caddy-tailscale-oauth = pkgs.buildGoModule rec {
    pname = "caddy-tailscale-oauth";
    version = "unstable-2024-01-15";

    src = pkgs.fetchFromGitHub {
      owner = "chrishoage";
      repo = "caddy-tailscale";
      rev = "559d3be3265d151136178bc04e4bf69a01c57889";
      sha256 = "sha256-XcKAx8n7oXM8qRt0Kz7krcF3mZbD9fTsemBAzKVerVQ=";
    };

    vendorHash = "sha256-xLRNY0x5jG6v7k3OC7Yn9bhZdGqOqY5LhpCBSmmUvmo=";

    doCheck = false;
  };
in
  # Build Caddy with the OAuth Tailscale plugin
  pkgs.caddy.override {
    buildGoModule = args:
      pkgs.buildGoModule (args
        // {
          pname = "caddy-with-tailscale";

          overrideModAttrs = _: {
            preBuild = ''
              echo 'package main
              import (
                _ "github.com/caddyserver/caddy/v2/modules/standard"
                _ "github.com/tailscale/caddy-tailscale"
              )' > main_override.go

              # Replace with the OAuth fork
              go get github.com/chrishoage/caddy-tailscale@${caddy-tailscale-oauth.src.rev}
              go mod tidy
            '';
          };

          preBuild = ''
            echo 'package main
            import (
              caddycmd "github.com/caddyserver/caddy/v2/cmd"
              _ "github.com/caddyserver/caddy/v2/modules/standard"
              _ "github.com/tailscale/caddy-tailscale"
            )
            func main() {
              caddycmd.Main()
            }' > cmd/caddy/main.go

            # Replace with the OAuth fork
            go get github.com/chrishoage/caddy-tailscale@${caddy-tailscale-oauth.src.rev}
            go mod tidy
          '';

          vendorHash = "sha256-AqPieper9pFGfFGZf2K7mk2Y8SgKNpFfhg5dTl5scWY=";
        });
  }
