{
  config,
  lib,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.blog;

  # Theme configuration
  themeRepo = pkgs.fetchFromGitHub {
    owner = "ejmg";
    repo = "hermit_zola";
    rev = "42c2c47ce25c4e0b9a2ec9fda6e6b17bf0c5c8a0";
    sha256 = "sha256-Z8iIIWr/pZq6X6lsWo3xXDJbF2UOpP5/HDQ6GWL7ey8=";
  };

  # Build the Zola site at build time
  builtSite = pkgs.stdenv.mkDerivation {
    name = "zola-blog-site";
    src = self + "/blog";

    nativeBuildInputs = [pkgs.zola];

    configurePhase = ''
      # Copy theme
      mkdir -p themes/hermit_zola
      cp -r ${themeRepo}/* themes/hermit_zola/

      # Ensure we have all required directories
      mkdir -p static/images
      mkdir -p content/posts
    '';

    buildPhase = ''
      zola build
    '';

    installPhase = ''
      cp -r public $out
    '';
  };
in {
  options.constellation.blog = {
    enable = mkEnableOption "Zola blog";

    domain = mkOption {
      type = types.str;
      default = "blog.arsfeld.dev";
      description = "Domain to serve the blog on";
    };
  };

  config = mkIf cfg.enable {
    # Ensure caddy is enabled
    services.caddy.enable = true;

    # Configure Caddy virtual host
    services.caddy.virtualHosts."${cfg.domain}" = {
      useACMEHost = "arsfeld.dev"; # Use existing certificate
      extraConfig = ''
        root * ${builtSite}
        file_server

        # Handle SPA-style routing for Zola
        try_files {path} {path}/ /index.html

        # Cache static assets
        @static {
          path *.css *.js *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot
        }
        header @static Cache-Control "public, max-age=31536000, immutable"

        # Security headers
        header {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          Referrer-Policy "no-referrer-when-downgrade"
          X-XSS-Protection "1; mode=block"
        }

        # Compress responses
        encode zstd gzip
      '';
    };
  };
}
