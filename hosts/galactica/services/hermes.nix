{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
  # Seeded once: Hermes owns config.yaml after first boot (schema migrations,
  # `hermes config set`, the dashboard), so tmpfiles `C` copies it only when absent.
  seedConfig = pkgs.writeText "hermes-config.yaml" ''
    model:
      default: deepseek-v4-flash
      provider: deepseek
      base_url: https://api.deepseek.com/v1
  '';
in {
  sops.secrets."hermes-env" = {};

  # Hermes Agent: personal AI agent gateway (OpenClaw alternative). All state —
  # sessions, memories, skills, cron, auth.json — lives in the /opt/data volume.
  # The dashboard sits behind Authelia and also requires its own basic-auth login:
  # it refuses to start on a non-loopback bind without an auth provider.
  media.services.hermes = {
    port = 9119;
    image = "docker.io/nousresearch/hermes-agent:latest";
    cmd = ["gateway" "run"];
    watchImage = true;
    container = {
      configDir = "/opt/data";
      environment = {
        HERMES_DASHBOARD = "1";
      };
      environmentFiles = [config.sops.secrets."hermes-env".path];
      # Chromium for browser tools needs shared memory.
      extraOptions = ["--shm-size=1g" "--memory=4g"];
    };
  };

  systemd.tmpfiles.rules = [
    "C ${vars.configDir}/hermes/config.yaml - - - - ${seedConfig}"
  ];
}
