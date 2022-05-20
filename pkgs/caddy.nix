prev: next:
with next;
rec {
  inherit (stdenv) isLinux isDarwin isAarch64;

  _caddy_plugins = [
    { name = "github.com/greenpau/caddy-security"; version = "v1.1.7"; }
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
      vendorSha256 = "sha256-fChvAGHl3MxVsBXH+qYiU8KXh0tgFTZo3JRS7X4aL2I=";
      overrideModAttrs = _: {
        preBuild = ''
          ${_caddy_patch_main}
          ${_caddy_patch_goget}
        '';
        postInstall = "cp go.mod go.sum $out/";
      };
      postPatch = _caddy_patch_main;
      preBuild = "cp vendor/go.mod vendor/go.sum .";
    });
  };
}
