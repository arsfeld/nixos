prev: next:
with next;
rec {
  inherit (stdenv) isLinux isDarwin isAarch64;

  _caddy_plugins = [
    { name = "github.com/greenpau/caddy-security"; version = "v1.1.7"; }
    { name = "github.com/lindenlab/caddy-s3-proxy"; version = "v0.5.6"; }
  ];
  _caddy_patch_main = prev.lib.strings.concatMapStringsSep "\n"
    ({ name, version }: ''
      sed -i '/plug in Caddy modules here/a\\t_ "${name}"' cmd/caddy/main.go
    '')
    _caddy_plugins;
  _caddy_patch_goget = prev.lib.strings.concatMapStringsSep "\n"
    ({ name, version }: ''
      go get ${name}@${version}
    '')
    _caddy_plugins;
  xcaddy = caddy.override {
    buildGoModule = args: buildGoModule (args // {
      vendorSha256 = "sha256-WHya9kbPGoImUa/6JnD220eOKKsHZUjEPpuzpQMAzJE=";
      overrideModAttrs = _: {
        preBuild = ''
          ${_caddy_patch_main}
          ${_caddy_patch_goget}
        '';
        postInstall = "cp go.mod go.sum $out/";
      };
      postInstall = ''
        ${args.postInstall}
        sed -i -E '/Group=caddy/aEnvironmentFile=/etc/default/caddy' $out/lib/systemd/system/caddy.service
      '';
      postPatch = _caddy_patch_main;
      preBuild = "cp vendor/go.mod vendor/go.sum .";
    });
  };
}
