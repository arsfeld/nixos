{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."morphic-env" = {};}

    (mkService "morphic" {
      port = 3000;
      image = "ghcr.io/miurla/morphic:latest";
      tailscaleExposed = true;
      watchImage = true;
      container = {
        environmentFiles = [
          config.sops.secrets."morphic-env".path
        ];
        environment = {
          # SearXNG is a native NixOS service on the host, reachable from
          # containers via the podman bridge gateway.
          SEARXNG_API_URL = "http://host.containers.internal:8888";
          SEARCH_API = "searxng";
          # Redis on the host (shared Seafile instance).
          LOCAL_REDIS_URL = "redis://10.88.0.1:6379";
          # Single-user guest mode (no Supabase auth).
          ENABLE_AUTH = "false";
        };
      };
    })
  ]
