# Example configuration for LLM-powered crash log analysis with agenix
{ config, pkgs, ... }:

{
  # Import the systemd email notification module
  imports = [ 
    ./modules/systemd-email-notify.nix 
  ];

  # Configure agenix for secret management
  age.secrets.google-api-key = {
    file = ./secrets/google-api-key.age;
    # Ensure the systemd email service can read the secret
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Configure email notifications with LLM analysis
  systemdEmailNotify = {
    # Email configuration
    toEmail = "admin@example.com";
    fromEmail = "noreply@example.com";
    
    # Enable AI-powered analysis
    enableLLMAnalysis = true;
    
    # Use the agenix secret for the API key
    googleApiKey = config.age.secrets.google-api-key.path;
  };

  # Example: Configure a service that might fail
  # This is just for demonstration purposes
  systemd.services.example-failing-service = {
    description = "Example service for testing crash notifications";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo \"Starting service...\"; exit 1'";
    };
    # The onFailure handler is automatically added by systemd-email-notify module
  };
}