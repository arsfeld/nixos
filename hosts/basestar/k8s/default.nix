# Lane A: manifests declared in nix and applied at activation.
#
# These render into services.k3s.manifests, whose content type is `attrs` or
# `listOf attrs`; a list becomes a single v1/List document. The k3s module
# links each generated file into /var/lib/rancher/k3s/server/manifests and the
# deploy controller applies it.
#
# Deleting an app from this file is NOT enough to remove it from the cluster -
# see the reconcile unit in modules/constellation/k3s.nix.
#
# Secrets never belong here: this content is rendered into the world-readable
# nix store. Use constellation.k3s.secrets instead.
{lib, ...}: let
  # mkApp lives in ./lib.nix, not in a `let` here, so that app #2 can be a
  # second module in this directory rather than an append to this file or a
  # copy of the helper. Import it the same way from any sibling:
  #
  #   inherit (import ./lib.nix {inherit lib;}) mkApp;
  #
  # Unused while this file declares no app, which is legal and deliberate - it
  # keeps the worked example below one line from compiling.
  inherit (import ./lib.nix {inherit lib;}) mkApp;
in {
  # No apps declared. `mkApp` is the entry point:
  #
  #   services.k3s.manifests.<name>.content = mkApp {
  #     name = "<name>"; image = "..."; port = 80; host = "<name>.arsfeld.dev";
  #   };
  #
  # Deleting such a block again is all that is needed - k3s-manifest-reconcile
  # in modules/constellation/k3s.nix deletes the objects, the AddOn and the
  # stale symlink on the next activation. That is how the whoami fixture this
  # file used to carry was removed, and proving that is what retired it.
}
