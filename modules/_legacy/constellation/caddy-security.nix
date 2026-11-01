# CVE-2026-111497 ("Broccoli2Shell"): reject Brotli-encoded request
# bodies at the edge, before a backend with a vulnerable Brotli decoder can
# process them. Defining the snippet once here avoids duplicate-snippet
# errors; vhosts opt in with `import no_brotli_requests`.
{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.services.caddy.enable {
    services.caddy.extraConfig = ''
      (no_brotli_requests) {
        @brotli_encoding header_regexp Content-Encoding (?i)(^|,)\s*br\s*(,|$)
        handle @brotli_encoding {
          respond "Brotli-encoded request bodies are disabled while CVE-2026-111497 is unpatched" 415
        }
      }
    '';
  };
}
