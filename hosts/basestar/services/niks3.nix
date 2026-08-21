# niks3 — the write half of the binary cache.
#
# niks3 is a coordinator, not a cache. Clients ask it for presigned R2 URLs,
# compress and PUT NARs straight to R2, then commit the closure; the server
# only records references in Postgres so GC can reclaim them later, and never
# handles NAR bytes. Reads never reach basestar at all — nix pulls from
# https://cache.arsfeld.dev, which is the R2 bucket behind a custom domain.
#
# That split is the whole point of replacing attic. atticd terminated uploads,
# ran zstd in-process and reassembled NARs on read, all through one replica on
# a 7.9 GiB k3s node it shared with a control plane; when it died, reads died
# with it and three tier-1 hosts stopped being deployable under `max-jobs = 0`.
# Here a server outage costs writes only.
{
  config,
  inputs,
  ...
}: {
  imports = [inputs.niks3.nixosModules.niks3];

  services.niks3 = {
    enable = true;
    httpAddr = "127.0.0.1:5751";
    # Caddy owns 80/443 on this host. The upstream module's nginx vhost would
    # fight it for the ports and for the arsfeld.dev certificate.
    nginx.enable = false;

    s3 = {
      endpoint = "67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com";
      bucket = "nix-cache";
      # Required for R2. Left empty, the client infers the region from the
      # endpoint and defaults to us-east-1, and every request then fails
      # signature verification.
      region = "auto";
      accessKeyFile = config.sops.secrets.r2-access-key-id.path;
      secretKeyFile = config.sops.secrets.r2-secret-access-key.path;
    };

    apiTokenFile = config.sops.secrets.niks3-api-token.path;
    signKeyFiles = [config.sops.secrets.niks3-sign-key.path];
    cacheUrl = "https://cache.arsfeld.dev";
    serverUrl = "https://niks3.arsfeld.dev";

    # CI authenticates with a short-lived GitHub OIDC token instead of a
    # long-lived secret in the repo. `audience` must match the audience the
    # workflow requests, and boundSubject matches GitHub's `sub` claim, which
    # for a push to master is `repo:arsfeld/nixos:ref:refs/heads/master`.
    oidc.providers.github = {
      issuer = "https://token.actions.githubusercontent.com";
      audience = "https://niks3.arsfeld.dev";
      boundClaims.repository_owner = ["arsfeld"];
      boundSubject = ["repo:arsfeld/nixos:*"];
    };

    # 30 days, not attic's 6 months, because CI pins the tier-1 closures. The
    # server's delete query is explicit about the exemption:
    #
    #   DELETE FROM closures
    #   WHERE closures.updated_at < $1
    #     AND closures.key NOT IN (SELECT narinfo_key FROM pins);
    #
    # Object GC then walks reachability from the surviving closures, so
    # everything beneath a pinned toplevel lives too. That decouples two
    # retention needs a single olderThan cannot serve: the closure
    # weekly-deploy needs can never age out from under it, while everything
    # else — including every derivation raider auto-uploads — expires in a
    # month. Shorten this before disabling auto-upload if the bucket grows.
    gc = {
      enable = true;
      olderThan = "720h";
    };

    # maxNarSize is deliberately left unset. Multipart upload handles large
    # closures; a cap makes clients silently skip store paths, which becomes a
    # cache miss on a host deploying under `max-jobs = 0`, where a miss is a
    # hard failure rather than a local rebuild.
  };

  # database.createLocally defaults true and contributes `local all niks3 peer`
  # to services.postgresql.authentication. planka's rules and nixpkgs' own
  # defaults are both lib.mkAfter while this one is normal-order, and the option
  # is types.lines, so the three definitions concatenate with this line first
  # rather than colliding — and pg_hba is first-match, so the niks3 line wins.
  # Nothing here disturbs planka's existing database.
  # The upstream module orders this unit after postgresql.service, which is not
  # enough: the `niks3` role is created by postgresql-setup.service, a oneshot
  # that runs *after* postgres is already listening. On a fresh activation niks3
  # therefore raced the role into existence and died with
  # `role "niks3" does not exist`, recovering only via Restart=always ten seconds
  # later — and firing this repo's OnFailure alert email every single time.
  # postgresql-setup.service is RemainAfterExit=yes, so depending on it is safe
  # and does not re-run the oneshot. Observed live on 2026-08-21; NRestarts=1 on
  # the bootstrap deploy.
  systemd.services.niks3 = {
    after = ["postgresql-setup.service"];
    requires = ["postgresql-setup.service"];
  };

  sops.secrets = {
    niks3-api-token = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    niks3-sign-key = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    r2-access-key-id = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    r2-secret-access-key = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
  };

  # DNS-only (grey-cloud) A record to this host — see CLAUDE.md. Only CI and
  # `just deploy` ever talk to this hostname, and no NAR traverses it, so the
  # usual reason to proxy (Cloudflare's 100 MB body limit) does not apply.
  services.caddy.virtualHosts."niks3.arsfeld.dev" = {
    useACMEHost = "arsfeld.dev";
    extraConfig = ''
      encode zstd gzip

      reverse_proxy 127.0.0.1:5751 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    '';
  };
}
