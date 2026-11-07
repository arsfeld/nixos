# eufy-sdk custom component for Home Assistant: the client half of the
# eufy-sdk stack. It talks to the ha-eufy-sdk-bridge container
# (modules/hosts/galactica/services/eufy.nix), which holds the eufy login.
#
# Bump version together with the bridge image tag there; the two are
# released as a pair.
{pkgs, ...}:
pkgs.buildHomeAssistantComponent rec {
  owner = "mega-yfue";
  domain = "eufy_sdk";
  version = "0.7.0";

  src = pkgs.fetchFromGitHub {
    owner = "mega-yfue";
    repo = "ha-eufy-sdk";
    tag = version;
    hash = "sha256-IgGWLo+ZqZhAYWuO/I2tkw9ePqy4CXf/5NOG+CzSfSc=";
  };

  meta = {
    description = "Eufy Security integration for Home Assistant, backed by eufy-sdk";
    homepage = "https://github.com/mega-yfue/ha-eufy-sdk";
    license = pkgs.lib.licenses.mit;
  };
}
