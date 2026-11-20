# macbook-pro: MacBook Pro (M2 Pro). Everything shared is in modules/darwin/;
# see "Macs (nix-darwin)" in CLAUDE.md.
{
  configurations.darwin.macbook-pro.module = {
    # The Pro was set up from these lists, so they are exact here: a cask or
    # formula dropped from modules/darwin/mac.nix is uninstalled on the next switch.
    homebrew.onActivation.cleanup = "uninstall";
  };
}
