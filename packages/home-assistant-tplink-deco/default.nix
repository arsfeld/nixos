# TP-Link Deco custom component for Home Assistant: polls the main Deco's
# local web API for mesh nodes and connected clients, exposing them as
# device trackers. Logs in with the Deco's local admin password, not the
# TP-Link cloud account.
{pkgs, ...}:
pkgs.buildHomeAssistantComponent rec {
  owner = "amosyuen";
  domain = "tplink_deco";
  version = "3.12.2";

  src = pkgs.fetchFromGitHub {
    owner = "amosyuen";
    repo = "ha-tplink-deco";
    tag = "v${version}";
    hash = "sha256-7Rp5Zv1P+yn0wD9zyEiDowXvi8zoeJBW0qdUyZZHehw=";
  };

  dependencies = [pkgs.home-assistant.python3Packages.pycryptodome];

  meta = {
    description = "TP-Link Deco mesh integration for Home Assistant";
    homepage = "https://github.com/amosyuen/ha-tplink-deco";
    license = pkgs.lib.licenses.mit;
  };
}
