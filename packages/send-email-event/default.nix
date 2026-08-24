{pkgs, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.jinja2
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
      export EMAIL_TEMPLATE=${./event-notification.html}
      # This script shells out to msmtpq, whose default connectivity probe is
      # `ping debian.org` — and ping is absent from a systemd unit's PATH, so
      # the probe always failed and msmtpq queued mail instead of sending it.
      # Skip the probe; msmtpq still queues if the real msmtp send fails.
      # See modules/constellation/email.nix for the full account.
      export EMAIL_CONN_TEST=x

      ${pythonEnv}/bin/python ${./send-email.py} "$@"
    '';
  }
