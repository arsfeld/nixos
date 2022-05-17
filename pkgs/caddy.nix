{
  lib,
  fetchFromGitHub,
  buildGoModule,
  plugins ? [],
  vendorSha256 ? "",
}:
with lib; let
  imports = flip concatMapStrings plugins (pkg: "\t\t\t_ \"${pkg}\"\n");

  version = "2.5.0";

  main = ''
    		package main

    		import (
    			caddycmd "github.com/caddyserver/caddy/v2/cmd"

    			_ "github.com/caddyserver/caddy/v2/modules/standard"
    ${imports}
    		)

    		func main() {
    			caddycmd.Main()
    		}
  '';
  dist = fetchFromGitHub {
    owner = "caddyserver";
    repo = "dist";
    rev = "v${version}";
    sha256 = "sha256-SUHwCGjtTy7nXianpUWDsgcVKpI/3DfRnU8kGFvIhZw=";
  };
in
  buildGoModule rec {
    pname = "caddy";
    inherit version;
    #runVend = true;
    subPackages = ["cmd/caddy"];

    src = fetchFromGitHub {
      owner = "caddyserver";
      repo = "caddy";
      rev = "v${version}";
      sha256 = "sha256-xNCxzoNpXkj8WF9+kYJfO18ux8/OhxygkGjA49+Q4vY=";
    };

    inherit vendorSha256;

    overrideModAttrs = _: {
      preBuild = "echo '${main}' > cmd/caddy/main.go";
      postInstall = "cp go.sum go.mod $out/ && ls $out/";
    };

    postPatch = ''
      echo '${main}' > cmd/caddy/main.go
      cat cmd/caddy/main.go
    '';

    postConfigure = ''
      cp vendor/go.sum ./
      cp vendor/go.mod ./
    '';

    postInstall = ''
      install -Dm644 ${dist}/init/caddy.service ${dist}/init/caddy-api.service -t $out/lib/systemd/system
      substituteInPlace $out/lib/systemd/system/caddy.service --replace "/usr/bin/caddy" "$out/bin/caddy"
      substituteInPlace $out/lib/systemd/system/caddy-api.service --replace "/usr/bin/caddy" "$out/bin/caddy"
    '';

    passthru.tests = {inherit (nixosTests) caddy;};

    meta = {
      homepage = https://caddyserver.com;
      description = "Fast, cross-platform HTTP/2 web server with automatic HTTPS";
      license = licenses.asl20;
      maintainers = with maintainers; [Br1ght0ne];
    };
  }
