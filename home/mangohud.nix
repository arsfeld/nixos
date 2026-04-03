# MangoHud performance overlay configuration
# Steam Deck-style 4-level preset cycling, loaded per-game only
{
  config,
  pkgs,
  lib,
  osConfig ? null,
  ...
}: let
  gamingEnabled =
    osConfig
    != null
    && (osConfig.constellation.gaming.enable or false)
    && (osConfig.constellation.gaming.performanceOsd or true);
  hostname =
    if osConfig != null
    then osConfig.networking.hostName
    else "";
  isG14 = hostname == "g14";
in {
  config = lib.mkIf gamingEnabled {
    programs.mangohud = {
      enable = true;
      enableSessionWide = false;
      settings =
        {
          # Preset cycling: 0=hidden, 1=fps, 2=detail, 3=full
          preset = "0,1,2,3";
          toggle_preset = "Shift_R+F12";
          toggle_hud = "Shift_R+F11";

          # Position and style
          position = "top-left";
          font_size = 18;
          offset_x = 10;
          offset_y = 10;
          background_alpha = "0.3";
          background_color = "020202";
          text_color = "ffffff";
          round_corners = 5;
        }
        // lib.optionalAttrs isG14 {
          # NVIDIA GTX 1660 Ti via PRIME offload (PCI:1:0:0)
          pci_dev = "0000:01:00.0";
        };
    };

    # Preset definitions for overlay cycling levels
    # Keybinds and global style are in MangoHud.conf (above),
    # presets define what each level displays
    xdg.configFile."MangoHud/presets.conf".text = ''
      [preset 0]
      no_display

      [preset 1]
      legacy_layout=0
      fps
      fps_only=1
      cpu_stats=0
      gpu_stats=0
      frametime=0
      frame_timing=0

      [preset 2]
      legacy_layout=0
      fps
      gpu_stats
      gpu_temp
      cpu_stats
      cpu_temp
      gpu_power
      cpu_power
      frametime=0
      frame_timing=1

      [preset 3]
      legacy_layout=0
      fps
      gpu_stats
      gpu_temp
      gpu_core_clock
      gpu_power
      cpu_stats
      cpu_temp
      cpu_mhz
      cpu_power
      vram
      ram
      frametime=1
      frame_timing=1
      ${lib.optionalString isG14 "battery"}
    '';
  };
}
