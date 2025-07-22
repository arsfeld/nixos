{pkgs, ...}: let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.jinja2
  ]);

  # Python environment for LLM analysis
  pythonEnvLLM = pkgs.python3.withPackages (ps: [
    ps.google-generativeai
  ]);

  # Main send-email-event script
  sendEmailEvent = pkgs.writeShellApplication {
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

      ${pythonEnv}/bin/python ${./send-email.py} "$@"
    '';
  };

  # LLM analysis script
  analyzeWithLLM = pkgs.writeShellApplication {
    name = "analyze-with-llm";
    runtimeInputs = [];
    text = ''
      ${pythonEnvLLM}/bin/python ${./analyze-with-llm.py} "$@"
    '';
  };

  # GitHub issue creation script
  createGitHubIssue = pkgs.writeShellApplication {
    name = "create-github-issue";
    runtimeInputs = [
      pkgs.gh
    ];
    text = ''
      ${pythonEnv}/bin/python ${./create-github-issue.py} "$@"
    '';
  };
in
  pkgs.symlinkJoin {
    name = "send-email-event";
    paths = [sendEmailEvent analyzeWithLLM createGitHubIssue];
  }
