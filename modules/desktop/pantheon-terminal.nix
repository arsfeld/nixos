# elementary Terminal on libghostty-gtk, a GTK4 terminal widget over libghostty-vt 1.0.0
# (packages/libghostty-gtk), in place of VTE. pkgs.elementary-terminal-ghostty is
# elementary's own Terminal built against libghostty-gtk instead of VTE.
#
# OSC 52 now comes from libghostty-gtk: programs such as zellij and Claude Code can set
# the clipboard (over SSH too), and libghostty-gtk reads it back only when programs may.
# This replaces the VTE patch this module used to carry.
#
# Both live in their own repos, kept upstreamable but not proposed upstream:
# libghostty-gtk at github.com/arsfeld/libghostty-gtk, and the port as commits on the `libghostty-gtk` branch
# of github.com/arsfeld/elementary-terminal, a fork of elementary/terminal.
# After a nixpkgs bump moves pantheon.elementary-terminal, rebase that branch
# onto the new release tag and bump packages/elementary-terminal-ghostty.
{
  flake.modules.nixos.pantheon-terminal = {
    key = "modules/desktop/pantheon-terminal";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: {
        config = lib.mkIf config.services.desktopManager.pantheon.enable {
          environment.pantheon.excludePackages = [pkgs.pantheon.elementary-terminal];
          environment.systemPackages = [pkgs.elementary-terminal-ghostty];
        };
      })
    ];
  };
}
