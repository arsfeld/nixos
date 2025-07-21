# GitHub notifications module for constellation
#
# This module provides GitHub issue creation for systemd service failures
# with automatic duplicate detection and gh CLI authentication.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.githubNotify;
in {
  options.constellation.githubNotify = {
    enable = mkEnableOption "GitHub notifications for systemd failures";

    username = mkOption {
      type = types.str;
      default = "arsfeld";
      description = "GitHub username";
    };

    repo = mkOption {
      type = types.str;
      default = "arsfeld/nixos";
      description = "GitHub repository for systemd failure issues";
    };

    tokenFile = mkOption {
      type = types.path;
      default = config.age.secrets.github-token.path;
      description = "Path to the GitHub token file (agenix secret)";
    };
  };

  config = mkIf cfg.enable {
    # Configure gh CLI with the token
    systemd.services.configure-gh = {
      description = "Configure GitHub CLI authentication for notifications";
      wantedBy = [ "multi-user.target" ];
      after = [ "agenix.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
      script = ''
        mkdir -p /root/.config/gh
        cat > /root/.config/gh/hosts.yml << EOF
        github.com:
          oauth_token: $(cat ${cfg.tokenFile})
          user: ${cfg.username}
          git_protocol: https
        EOF
        chmod 600 /root/.config/gh/hosts.yml
      '';
    };

    # Ensure gh is available system-wide
    environment.systemPackages = [ pkgs.gh ];

    # Enable GitHub issues for systemd failures if email notifications are configured
    systemdEmailNotify = mkIf (config.constellation.email.enable) {
      enableGitHubIssues = true;
      gitHubRepo = cfg.repo;
    };
  };
}