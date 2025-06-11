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
    owner = "VersBinarii";
    repo = "hermit_zola";
    rev = "94faef2295e2a64190a0e0f6760920ab54924847";
    sha256 = "sha256-nv9X8gECfXJo9j/o0ZJz5gcDTc8tcjlKUXdNRS1gB+A=";
  };

  # Build the Zola site at build time
  builtSite = pkgs.stdenv.mkDerivation {
    name = "zola-blog-site";
    src = self + "/blog";

    nativeBuildInputs = [pkgs.zola];

    configurePhase = ''
      # Copy theme to a writable location
      mkdir -p themes/hermit_zola
      cp -r ${themeRepo}/* themes/hermit_zola/
      chmod -R u+w themes/hermit_zola

      # Fix deprecated feed_filename usage in theme
      find themes/hermit_zola -name "*.html" -type f -exec sed -i 's/config\.feed_filename/config.feed_filenames[0]/g' {} \;

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
