# The arsfeld/yarr fork: upstream nkanaev/yarr plus one commit, a Google Reader
# API (/accounts/ClientLogin, /reader/api/0/*) so NetNewsWire can sync. Add it in
# NetNewsWire as a "FreshRSS" account with https://yarr.arsfeld.one as the URL
# and the YARR_AUTH credentials. Upstream only has Fever, which NetNewsWire does
# not speak. The fork's CI publishes :master on every push; watchImage pulls it.
# Keep the fork a single commit rebased onto upstream master.
#
# YARR_AUTH authenticates both APIs: Fever's api_key is md5(user:pass), and the
# Reader API's ClientLogin token is derived from the same pair. With no
# credentials set Fever lets everyone in (the Reader API refuses instead). Both
# bypass Authelia (services/auth.nix), so this secret is the only thing guarding
# them.
{
  configurations.nixos.galactica.module = {config, ...}: {
    sops.secrets."yarr-env" = {};

    media.services.yarr = {
      # Probe-verified: root process writes /data owned by media (5000) and failed with EACCES without caps.
      # DAC_OVERRIDE: write dirs/files owned by another uid.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
      port = 7070;
      image = "ghcr.io/arsfeld/yarr:master";
      watchImage = true;
      tailscaleExposed = true;
      container = {
        exposePort = 7070;
        configDir = "/data";
        environmentFiles = [
          config.sops.secrets."yarr-env".path
        ];
      };
    };
  };
}
