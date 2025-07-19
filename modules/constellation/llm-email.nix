# Constellation LLM-powered email notification module
#
# This module enhances the email notification system with AI-powered crash log
# analysis using Google's Gemini API. When enabled alongside the base email
# module, it provides intelligent insights for system failures.
#
# Key features:
# - AI-powered analysis of systemd service failures
# - Root cause identification and resolution suggestions
# - Secure API key storage using agenix
# - Integration with existing email notification system
# - Free tier support (6M tokens/day with Gemini)
#
# The module automatically enables systemd-email-notify with LLM analysis
# when both email notifications and this module are enabled.
{
  lib,
  pkgs,
  config,
  self,
  ...
}:
with lib; {
  options.constellation.llmEmail = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable AI-powered analysis for systemd service failure notifications.
        Requires constellation.email to be enabled and a Google API key.
        
        This adds intelligent crash log analysis to email notifications,
        providing root cause analysis and resolution suggestions.
      '';
    };

    googleApiKeyFile = mkOption {
      type = types.str;
      default = "${self}/secrets/google-api-key.age";
      description = ''
        Path to the agenix-encrypted Google API key file.
        Get your free API key from https://aistudio.google.com/apikey
      '';
    };
  };

  config = lib.mkIf (config.constellation.email.enable && config.constellation.llmEmail.enable) {
    # Import the systemd email notification module
    imports = [ ../systemd-email-notify.nix ];

    # Configure the agenix secret for Google API key
    age.secrets.google-api-key = {
      file = config.constellation.llmEmail.googleApiKeyFile;
      mode = "0400";
      owner = "root";
      group = "root";
    };

    # Configure systemd email notifications with LLM analysis
    systemdEmailNotify = {
      # Use email addresses from constellation.email
      toEmail = mkDefault config.constellation.email.toEmail;
      fromEmail = mkDefault config.constellation.email.fromEmail;
      
      # Enable LLM analysis
      enableLLMAnalysis = true;
      googleApiKey = config.age.secrets.google-api-key.path;
    };
  };
}