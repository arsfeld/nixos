{pkgs, ...}: let
  # Use python312 because mrml doesn't support Python 3.13 yet (PyO3 version issue)
  pythonEnv = pkgs.python312.withPackages (ps:
    with ps; [
      playwright
      mrml
      requests
    ]);
in
  pkgs.writeShellApplication {
    name = "check-stock";
    runtimeInputs = [pkgs.msmtp];
    text = ''
      export PLAYWRIGHT_BROWSERS_PATH=${toString pkgs.playwright-driver.browsers}
      export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
      export EMAIL_TEMPLATE_PATH=${./email-template.mjml}
      ${pythonEnv}/bin/python ${./check-stock.py} "$@"
    '';
  }
