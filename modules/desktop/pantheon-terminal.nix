# elementary Terminal on gvt, a GTK4 terminal widget over libghostty-vt 1.0.0
# (packages/gvt), in place of VTE. pkgs.elementary-terminal-ghostty is
# elementary's own Terminal built against gvt instead of VTE.
#
# OSC 52 now comes from gvt: programs such as zellij and Claude Code can set
# the clipboard (over SSH too), and gvt reads it back only when programs may.
# This replaces the VTE patch this module used to carry.
#
# elementary's patch lives in packages/elementary-terminal-ghostty/gvt.patch.
# To rebase it after a nixpkgs bump moves pantheon.elementary-terminal, unpack
# the new source, reapply the hunks by hand (they swap the VTE widget and its
# API calls for gvt's) and regenerate the patch with `diff -u`.
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
