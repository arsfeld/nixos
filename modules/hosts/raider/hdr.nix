# HDR on raider's Gigabyte M34WQ (HDR400), which Pantheon's Displays page has no
# switch for although Gala's Mutter supports it.
#
# Two pieces of state, and only one can live here:
# - The colour mode (BT.2100) is in ~/.config/monitors.xml, which Mutter owns
#   and rewrites on every display change, so nix must not manage it. Set it with
#   `gdctl set --persistent --logical-monitor --primary --monitor DP-4
#   --color-mode bt2100` (`default` turns HDR off).
# - The brightness of SDR content in HDR mode is `output-luminance`, a percentage
#   (Mutter's default 100 is far too dim on this panel). It is a dconf key, so a
#   system default here holds it; a value set at runtime through DisplayConfig's
#   SetLuminance lands in the user database and wins.
#
# Both are keyed on the connector: moving the cable to another port (it has been
# on DP-2 before) starts over at SDR and 100%.
{
  configurations.nixos.raider.module = {
    lib,
    pkgs,
    ...
  }: {
    # gdctl from the Mutter Gala runs on, not pkgs.mutter (a newer major).
    environment.systemPackages = [pkgs.pantheon.mutter];

    programs.dconf.profiles.user.databases = [
      {
        settings."org/gnome/mutter".output-luminance = [
          (lib.gvariant.mkTuple [
            "DP-4"
            "GBT"
            "M34WQ"
            "0x00000654"
            (lib.gvariant.mkUint32 1) # colour mode: BT.2100
            200.0
          ])
        ];
      }
    ];
  };
}
