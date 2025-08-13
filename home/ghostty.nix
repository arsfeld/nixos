{
  config,
  pkgs,
  lib,
  ...
}: {
  # Ghostty configuration to properly pass Alt+Arrow keys to Zellij
  xdg.configFile."ghostty/config" = {
    text = ''
      # Disable Ghostty's default Alt+Arrow tab navigation
      # This allows the keys to pass through to Zellij
      keybind = clear

      # Re-add essential Ghostty keybindings you want to keep
      keybind = ctrl+shift+c=copy_to_clipboard
      keybind = ctrl+shift+v=paste_from_clipboard
      keybind = ctrl+shift+n=new_window
      keybind = ctrl+shift+q=quit
      keybind = ctrl+plus=increase_font_size:1
      keybind = ctrl+minus=decrease_font_size:1
      keybind = ctrl+zero=reset_font_size

      # Optional: Add other Ghostty settings you might want
      font-family = FiraCode Nerd Font
      font-size = 12
      theme = dark
      cursor-style = block
      cursor-style-blink = true

      # Ensure proper terminal behavior for Zellij
      window-decoration = true
      confirm-close-surface = false

      keybind = shift+enter=text:\n
    '';
  };
}
