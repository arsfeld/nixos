{pkgs, ...}: {
  programs.helix = {
    enable = true;

    settings = {
      editor = {
        line-number = "relative";
        mouse = true;
        rulers = [120];
        true-color = true;
        completion-replace = true;
        trim-trailing-whitespace = true;
        end-of-line-diagnostics = "hint";
        color-modes = true;
        rainbow-brackets = true;

        inline-diagnostics = {
          cursor-line = "warning";
        };

        file-picker = {
          hidden = false;
        };

        indent-guides = {
          render = true;
          character = "╎";
          skip-levels = 0;
        };

        soft-wrap = {
          enable = false;
        };

        auto-save = {
          focus-lost = true;
          after-delay = {
            enable = true;
            timeout = 300000;
          };
        };
      };
    };
  };
}
