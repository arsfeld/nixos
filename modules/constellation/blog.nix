# Constellation blog module
#
# This module sets up a static blog using Zola, a fast static site generator
# written in Rust. The blog is automatically built at NixOS configuration time
# and served via Caddy web server.
#
# Key features:
# - Static site generation with Zola at build time
# - Custom theme with flexible layout and styling
# - Caddy web server with proper caching and security headers
# - ACME/Let's Encrypt SSL certificate support
# - Compression with zstd and gzip
# - SPA-style routing support
# - Integration with self-hosted Plausible Analytics
#
# The blog content is expected to be in the /blog directory of the repository,
# and the built site is served from the specified domain.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.blog;

  # Build the Zola site at build time
  builtSite = pkgs.stdenv.mkDerivation {
    name = "zola-blog-site";
    src = self + "/blog";

    nativeBuildInputs = [pkgs.zola pkgs.sass];

    configurePhase = ''
      # The custom theme is already in the blog directory
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
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable the Zola static blog generator and Caddy web server.
        This will build your blog at configuration time and serve it
        with proper caching, compression, and security headers.
      '';
      default = false;
    };

    domain = mkOption {
      type = types.str;
      default = "blog.arsfeld.dev";
      description = ''
        The domain name where the blog will be served.
        This domain will be configured in Caddy with ACME certificates.
      '';
      example = "blog.example.com";
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
