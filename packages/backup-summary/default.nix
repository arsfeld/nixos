{pkgs, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.jinja2
  ]);
in
  pkgs.writeShellApplication {
    name = "backup-summary";
    runtimeInputs = [
      pythonEnv
      pkgs.restic
      pkgs.rustic
      pkgs.msmtp
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      export EMAIL_TEMPLATE=${./summary-email.html.j2}
      exec ${pythonEnv}/bin/python ${./backup_summary.py} "$@"
    '';
  }
