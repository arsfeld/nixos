# niks3 binary cache: the push token, post-build auto-upload, and the token path for `just deploy`.
{inputs, ...}: {
  configurations.nixos.raider.module = {config, ...}: {
    imports = [inputs.niks3.nixosModules.niks3-auto-upload];

    # Full-write cache credential on a workstation, which is worth naming
    # explicitly. niks3 supports exactly one API token alongside OIDC, so there
    # is no lower-privilege token to hand raider short of mTLS. It is not a
    # regression: raider already held an attic write token in
    # ~/.config/attic/config.toml.
    #
    # owner + mode let the interactive user read it, not just root. The
    # auto-upload daemon runs as root and could read it either way; the reason
    # for the user-readable mode is `nix-fast-build --niks3-server`, whose
    # upload worker shells out to `niks3 push` as the invoking user and resolves
    # its token from $NIKS3_AUTH_TOKEN_FILE. That avoids a second copy of the
    # token in ~/.config/niks3/auth-token.
    sops.secrets."niks3-api-token" = {
      owner = "arosenfeld";
      mode = "0400";
    };

    # Every derivation raider builds is uploaded as it finishes — not just what
    # CI builds or what `just deploy` pushes.
    #
    # The post-build hook itself does almost nothing: it writes the store path
    # to a unix socket and exits. That matters, because a post-build hook runs
    # inside every build, and one that uploaded synchronously would serialise
    # every build behind network I/O. The socket-activated daemon on the other
    # end batches 50 paths, uploads with 30-way concurrency, and exits after 60s
    # idle; behind it is a WAL-mode SQLite queue, so paths survive a crash or a
    # reboot mid-upload instead of being silently lost.
    #
    # raider only. blackbird is a laptop that is frequently tethered or offline,
    # and pushing every local build over a metered link is the wrong default;
    # galactica and basestar are deploy targets that rarely build anything not
    # already coming from CI.
    #
    # Note that post-build-hook is a global nix setting, not a list. Nothing
    # else in this repo sets one today, but a future module that wants one will
    # collide with this rather than compose with it.
    services.niks3-auto-upload = {
      enable = true;
      serverUrl = "https://niks3.arsfeld.dev";
      authTokenFile = config.sops.secrets."niks3-api-token".path;
    };

    # `just deploy` phase 1 pushes through nix-fast-build --niks3-server,
    # whose upload worker runs `niks3 push` as this user. Pointing it at the
    # sops secret keeps a single copy of the token on disk.
    environment.sessionVariables.NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
  };
}
