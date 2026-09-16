# Hilo (Hydro-Québec demand response) custom component for Home Assistant.
#
# Pinned here rather than installed through HACS: Home Assistant on NixOS runs
# with pip disabled, so a HACS update that raises the python-hilo floor would
# fail to load. Bump version and python-hilo (overlays/python-packages.nix)
# together.
{pkgs, ...}:
pkgs.buildHomeAssistantComponent rec {
  owner = "dvd-dev";
  domain = "hilo";
  version = "2026.9.5";

  src = pkgs.fetchFromGitHub {
    owner = "dvd-dev";
    repo = "hilo";
    tag = "v${version}";
    hash = "sha256-npAxmQj12o+HsfUNk8inUiiAkvk5zB2x5o927ExxOas=";
  };

  dependencies = [pkgs.home-assistant.python3Packages.python-hilo];

  meta = {
    description = "Hilo (Hydro-Québec) integration for Home Assistant";
    homepage = "https://github.com/dvd-dev/hilo";
    license = pkgs.lib.licenses.mit;
  };
}
