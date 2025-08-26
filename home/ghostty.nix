{
  config,
  pkgs,
  lib,
  ...
}: {
  # Ghostty configuration to properly pass Alt+Arrow keys to Zellij
  xdg.configFile."ghostty/config" = {
    text = ''
      # Essential Ghostty keybindings
      keybind = ctrl+shift+c=copy_to_clipboard
      keybind = ctrl+shift+v=paste_from_clipboard
      keybind = ctrl+shift+n=new_window
      keybind = ctrl+shift+q=quit
      keybind = ctrl+plus=increase_font_size:1
      keybind = ctrl+minus=decrease_font_size:1
      keybind = ctrl+zero=reset_font_size

      # Tab management keybindings
      keybind = ctrl+shift+t=new_tab
      keybind = ctrl+shift+tab=new_tab
      keybind = ctrl+shift+w=close_surface
      keybind = ctrl+page_up=previous_tab
      keybind = ctrl+page_down=next_tab
      keybind = alt+1=goto_tab:1
      keybind = alt+2=goto_tab:2
      keybind = alt+3=goto_tab:3
      keybind = alt+4=goto_tab:4
      keybind = alt+5=goto_tab:5
      keybind = alt+6=goto_tab:6
      keybind = alt+7=goto_tab:7
      keybind = alt+8=goto_tab:8
      keybind = alt+9=goto_tab:9

      # Window and view management
      keybind = f11=toggle_fullscreen
      keybind = ctrl+shift+a=select_all

      # Search functionality (workaround until native search is implemented)
      # Opens scrollback in default text editor where you can search
      keybind = ctrl+shift+f=write_scrollback_file:open

      # Scrolling
      keybind = shift+page_up=scroll_page_up
      keybind = shift+page_down=scroll_page_down
      keybind = shift+home=scroll_to_top
      keybind = shift+end=scroll_to_bottom

      # Optional: Add other Ghostty settings you might want
      font-family = FiraCode Nerd Font
      font-size = 12
      theme = catppuccin-frappe
      cursor-style = block
      cursor-style-blink = true

      # Transparency and blur settings
      background-opacity = 0.85
      background-blur-radius = 20
      unfocused-split-opacity = 0.9

      # Ensure proper terminal behavior for Zellij
      window-decoration = true
      confirm-close-surface = false

      # Shift+Enter sends a newline
      keybind = shift+enter=text:\\x0a
    '';
  };
}
