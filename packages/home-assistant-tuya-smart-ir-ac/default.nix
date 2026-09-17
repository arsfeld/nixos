# Tuya Smart IR AC custom component for Home Assistant: IR air conditioners
# behind a Tuya Smart IR hub, which the built-in tuya integration lists as
# unsupported. Talks to the Tuya IoT Cloud with a developer project's
# Access ID/Secret, not the Smart Life login the built-in integration uses.
{pkgs, ...}:
pkgs.buildHomeAssistantComponent rec {
  owner = "EnzoD86";
  domain = "tuya_smart_ir_ac";
  version = "2026.9.0";

  src = pkgs.fetchFromGitHub {
    owner = "EnzoD86";
    repo = "tuya-smart-ir-ac";
    tag = version;
    hash = "sha256-vmlGWgWSv/lJm88uP0YMFUjx9Umm+XytkABqD4RirvY=";
  };

  # The vendored tuya_connector imports Crypto.Cipher, which the manifest
  # does not declare.
  dependencies = [pkgs.home-assistant.python3Packages.pycryptodome];

  meta = {
    description = "Tuya IR air conditioner integration for Home Assistant";
    homepage = "https://github.com/EnzoD86/tuya-smart-ir-ac";
    license = pkgs.lib.licenses.mit;
  };
}
