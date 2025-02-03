{pkgs, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      playwright
      mrml
      pkgs.msmtp
    ]);
in
  pkgs.writeShellApplication {
    name = "check-stock";
    runtimeInputs = [pkgs.playwright-driver];
    text = ''
      export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
      export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
      ${pythonEnv}/bin/python ${./check-stock.py} -t ${./email-template.mjml} "$@"
    '';
  }
