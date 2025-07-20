# Systemd email notification module
#
# This module provides automatic email notifications for systemd service failures.
# It integrates with systemd's onFailure mechanism to send detailed failure reports
# including service status and recent logs.
#
# Features:
# - Automatic email on service failure
# - Rate limiting to prevent notification spam (1 hour cooldown)
# - Failure count tracking
# - HTML-formatted service status and logs
# - Integration with constellation email configuration
# - Optional GitHub issue creation with duplicate detection
#
# The module automatically adds onFailure handlers to all systemd services,
# ensuring comprehensive monitoring coverage across the system.
#
# Example usage:
#   systemdEmailNotify = {
#     toEmail = "admin@example.com";
#     fromEmail = "noreply@example.com";
#     enableLLMAnalysis = true;
#     googleApiKey = config.age.secrets.google-api-key.path;
#     enableGitHubIssues = true;
#     gitHubRepo = "owner/repo";
#     gitHubUpdateInterval = 24;
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  sendmail = pkgs.writeScript "sendmail" ''
    #!/bin/sh

    set -eu

    SERVICE_NAME="$1"
    COOLDOWN_SECONDS=3600  # 1 hour cooldown
    TIMESTAMP_FILE="/tmp/service_failure_$SERVICE_NAME.timestamp"
    FAILURE_COUNT_FILE="/tmp/service_failure_$SERVICE_NAME.count"

    update_failure_count() {
      FAILURE_COUNT=$(( $(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
      echo "$FAILURE_COUNT" > "$FAILURE_COUNT_FILE"
    }

    check_cooldown() {
      [ -f "$TIMESTAMP_FILE" ] || return 0
      LAST_NOTIFICATION=$(cat "$TIMESTAMP_FILE")
      CURRENT_TIME=$(date +%s)
      [ $((CURRENT_TIME - LAST_NOTIFICATION)) -ge $COOLDOWN_SECONDS ]
    }

    update_failure_count

    if ! check_cooldown; then
      echo "Rate limit: Not sending email for service $SERVICE_NAME. Failure count: $FAILURE_COUNT"
      exit 0
    fi

    date +%s > "$TIMESTAMP_FILE"

    # Update the timestamp file
    date +%s > "$TIMESTAMP_FILE"

    export EMAIL_TO=${config.systemdEmailNotify.toEmail}
    export EMAIL_FROM=${config.systemdEmailNotify.fromEmail}

    # Capture logs and status to temporary files for LLM analysis
    LOG_FILE=$(mktemp)
    STATUS_FILE=$(mktemp)
    
    SYSTEMD_COLORS=1 journalctl -u "$1" --reverse --lines=50 -b > "$LOG_FILE"
    SYSTEMD_COLORS=1 systemctl status --full "$1" > "$STATUS_FILE"
    
    # Perform LLM analysis if enabled and API key is available
    LLM_ANALYSIS=""
    if [ "${toString config.systemdEmailNotify.enableLLMAnalysis}" = "1" ]; then
      # Handle both direct API key and agenix secret file
      if [ -f "${config.systemdEmailNotify.googleApiKey}" ]; then
        # It's a file path (agenix secret)
        export GOOGLE_API_KEY=$(cat "${config.systemdEmailNotify.googleApiKey}")
      elif [ -n "${config.systemdEmailNotify.googleApiKey}" ]; then
        # It's a direct API key
        export GOOGLE_API_KEY="${config.systemdEmailNotify.googleApiKey}"
      fi
      
      if [ -n "$GOOGLE_API_KEY" ]; then
        LLM_ANALYSIS=$(${pkgs.send-email-event}/bin/analyze-with-llm "$1" "$LOG_FILE" "$STATUS_FILE" 2>/dev/null || echo "")
        
        if [ -n "$LLM_ANALYSIS" ]; then
        LLM_ANALYSIS="
        
        <h3 style='color: #1f2937; font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Arial, sans-serif;'>AI Analysis</h3>
        <div style='background-color: #f0f4ff; border: 1px solid #4a90e2; border-radius: 8px; padding: 16px; margin: 16px 0;'>
        <pre style='white-space: pre-wrap; font-family: monospace; color: #1f2937; margin: 0;'>$LLM_ANALYSIS</pre>
        </div>"
        fi
      fi
    fi
    
    # Convert logs to HTML
    LOG_HTML=$(cat "$LOG_FILE" | ${pkgs.aha}/bin/aha -n)
    STATUS_HTML=$(cat "$STATUS_FILE" | ${pkgs.aha}/bin/aha -n)
    
    # Create GitHub issue if enabled
    if [ "${toString config.systemdEmailNotify.enableGitHubIssues}" = "1" ] && [ -n "${config.systemdEmailNotify.gitHubRepo}" ]; then
      LLM_FILE=""
      if [ -n "$LLM_ANALYSIS" ]; then
        LLM_FILE=$(mktemp)
        echo "$LLM_ANALYSIS" | sed 's/<[^>]*>//g' > "$LLM_FILE"
      fi
      
      ${pkgs.send-email-event}/bin/create-github-issue \
        --repo "${config.systemdEmailNotify.gitHubRepo}" \
        --service "$1" \
        --hostname "$(hostname)" \
        --status "$STATUS_FILE" \
        --journal "$LOG_FILE" \
        --failure-count "$FAILURE_COUNT" \
        ${optionalString (config.systemdEmailNotify.enableLLMAnalysis) "--llm-analysis \"$LLM_FILE\""} \
        --update-interval ${toString config.systemdEmailNotify.gitHubUpdateInterval} || true
      
      [ -n "$LLM_FILE" ] && rm -f "$LLM_FILE"
    fi
    
    # Clean up temp files
    rm -f "$LOG_FILE" "$STATUS_FILE"

    ${pkgs.send-email-event}/bin/send-email-event \
      "Service Failure $1 (Failure #$FAILURE_COUNT)" \
      "Failed Service: $1
        Failure Count: $FAILURE_COUNT
        $LLM_ANALYSIS

        Service Status:
        $STATUS_HTML

        Recent Logs:
        $LOG_HTML"

    echo 0 > "$FAILURE_COUNT_FILE"
  '';
in {
  options = {
    systemd.services = mkOption {
      type = with types;
        attrsOf (
          submodule {
            config.onFailure = ["email@%n.service"];
          }
        );
    };

    systemdEmailNotify.toEmail = mkOption {
      type = types.str;
      default = config.constellation.email.toEmail;
      description = ''
        Email address to send service failure notifications to.
        Defaults to the constellation email configuration if available.
      '';
    };

    systemdEmailNotify.fromEmail = mkOption {
      type = types.str;
      default = config.constellation.email.fromEmail;
      description = ''
        Email address to use as the sender for service failure notifications.
        Defaults to the constellation email configuration if available.
      '';
    };

    systemdEmailNotify.enableLLMAnalysis = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable AI-powered analysis of service failures using Google's Gemini API.
        Requires googleApiKey to be set.
      '';
    };

    systemdEmailNotify.googleApiKey = mkOption {
      type = types.str;
      default = "";
      description = ''
        Google API key for Gemini AI analysis.
        Get your free API key from https://aistudio.google.com/apikey
      '';
    };

    systemdEmailNotify.enableGitHubIssues = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable automatic GitHub issue creation for service failures.
        Requires gitHubRepo to be set and gh CLI to be authenticated.
      '';
    };

    systemdEmailNotify.gitHubRepo = mkOption {
      type = types.str;
      default = "";
      description = ''
        GitHub repository (owner/repo) where issues should be created.
        Example: "arsfeld/nixos"
      '';
    };

    systemdEmailNotify.gitHubUpdateInterval = mkOption {
      type = types.int;
      default = 24;
      description = ''
        Hours before creating a new issue instead of updating an existing one.
        If a service fails multiple times within this interval, the existing
        issue will be updated with comments instead of creating duplicates.
      '';
    };
  };

  config = {
    systemd.services."email@" = {
      description = "Sends a status mail via sendEmailEvent on service failures.";
      onFailure = mkForce [];
      serviceConfig = {
        ExecStart = "${sendmail} %i";
        Type = "oneshot";
      };
    };
  };
}
