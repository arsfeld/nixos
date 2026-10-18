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
  version = "2026.10.2";

  src = pkgs.fetchFromGitHub {
    owner = "dvd-dev";
    repo = "hilo";
    tag = "v${version}";
    hash = "sha256-ta+7NBNXr2snBT7jlbUMZOz5mUeVQ7w5Omfek0Q+g2o=";
  };

  dependencies = [pkgs.home-assistant.python3Packages.python-hilo];

  meta = {
    description = "Hilo (Hydro-Québec) integration for Home Assistant";
    homepage = "https://github.com/dvd-dev/hilo";
    license = pkgs.lib.licenses.mit;
  };
}
