# elementary Terminal with OSC 52 copies. VTE ignores OSC 52, so zellij and
# Claude Code, which copy with it (over SSH too), never reached the clipboard.
# The patch makes VTE accept OSC 52 writes; a "?" read request is still never
# answered, so programs can set the clipboard but not read it. It also raises
# VTE's 4096-character limit on an OSC string, which capped a copy at about
# 3 KiB.
#
# Only elementary Terminal gets the patched VTE. Rebuilding vte-gtk4 for the
# whole system would rebuild everything that links it.
#
# The patch is against VTE 0.84.1. When a nixpkgs bump moves VTE and the patch
# no longer applies, rebase it: the hunks touch only src/vteseq.cc (OSC
# dispatch), src/vte.cc and src/vteinternal.hh (the new method) and
# src/parser-string.hh (the length limit).
{
  flake.modules.nixos.pantheon-terminal = {
    key = "modules/desktop/pantheon-terminal";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        vte = pkgs.vte-gtk4.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./_vte-osc52-clipboard.patch];
        });
        terminal = pkgs.pantheon.elementary-terminal.override {vte-gtk4 = vte;};
      in {
        config = lib.mkIf config.services.desktopManager.pantheon.enable {
          environment.pantheon.excludePackages = [pkgs.pantheon.elementary-terminal];
          environment.systemPackages = [terminal];
        };
      })
    ];
  };
}
