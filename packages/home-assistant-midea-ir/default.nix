# Midea IR custom component for Home Assistant: a climate entity for
# Midea-protocol air conditioners (the living room Kanion heat pump), which
# builds each IR frame itself and sends it through an existing remote entity
# such as a tuya_local IR hub. Written here; there is no upstream.
{pkgs, ...}:
pkgs.buildHomeAssistantComponent {
  owner = "arsfeld";
  domain = "midea_ir";
  version = "0.1.0";

  src = ./.;

  # Every learned Kanion code must round-trip through the encoder.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    PYTHONPATH=custom_components/midea_ir ${pkgs.python3.interpreter} ${./check.py}
    runHook postInstallCheck
  '';

  meta = {
    description = "Midea-protocol IR air conditioner climate entity for Home Assistant";
    license = pkgs.lib.licenses.mit;
  };
}
