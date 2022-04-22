let
  pkgs = import <nixpkgs> {};
  colmena =
    import (builtins.fetchTarball
      https://github.com/zhaofengli/colmena/tarball/main);
in
  with pkgs;
    mkShell {
      nativeBuildInputs = [
        direnv
        colmena
      ];

      NIX_ENFORCE_PURITY = true;

      shellHook = ''
      '';
    }
