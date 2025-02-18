{pkgs, config, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.jinja2
    ps.mrml
  ]);
in
  pkgs.writeShellApplication {
    name = "send-email-event";
    runtimeInputs = [
      pkgs.aha
      pkgs.figlet
      pkgs.coreutils
      pkgs.procps
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.gawk
      pkgs.msmtp
    ];
    text = ''
      export EMAIL_TEMPLATE=${./event-notification.mjml}

      ${pythonEnv}/bin/python ${./send-email.py} "$@"
    '';
  }
