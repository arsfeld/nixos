# plab: one Rust daemon (packages/plab) for three jobs that used to be separate Python
# tools: the tracker app (Videos and Games, "Add to Vault"/"Add to Games"), Stash
# identification of every new Vault file (was stash-identify), and studio grabs through
# Prowlarr (was vault-grab), plus pruning finished torrents. Its tasks share one tracker
# session and one SQLite database, /var/lib/plab/state.db.
#
# Design: docs/superpowers/specs/2026-11-01-plab-rust-merge-design.md
# Provenance (which download a scene came from, its status on the page, tracker covers):
# docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md
# The page is a Svelte app (packages/plab/ui, built as plab.ui) over plab's JSON API and
# its SSE stream (/api/events); the jobs monitor is its Jobs tab.
# Design: docs/superpowers/specs/2026-11-02-plab-svelte-app-design.md
# Earlier designs: 2026-10-09-plab-design.md, 2026-09-27-stash-llm-identify-design.md,
# 2026-10-24-vault-grab-design.md (behaviour unchanged by the port).
#
# Every job also runs once from the CLI, beside the daemon:
#   sudo -u media plab prune --dry-run      what prune would remove
#   sudo -u media plab grab --dry-run       what grab would add
#   sudo -u media plab identify --dry-run --scene <id>
#   sudo -u media plab refresh
# prune keeps a finished video torrent until its files are recorded (state.db's
# download_file table): grabs are removed as soon as they finish, and the file list goes with them.
# If a login ever hits a captcha: log in once in a browser and run
# `sudo -u media plab set-cookie <bb_data cookie value>`. No restart needed.
#
# Streaming (the page's Stream button): `plab-stream` is rqbit inside the PIA namespace,
# outbound only and without persistence; its scratch dir is emptied whenever it starts or
# stops, and it is PartOf plab. Its unit is sandboxed so rqbit can write only that dir (the
# reason is at the unit). VLC reaches plab's GET-only stream listener through the tailnet node
# plab-stream.<tailnet>. torrent_file keeps every grabbed .torrent.
# Design: docs/superpowers/specs/2026-11-02-plab-streaming-design.md
#
# Rollback: revert this commit. The legacy JSON state under /var/lib/{plab,stash-identify,
# vault-grab} is never modified by the daemon, so the Python resumes where it stopped.
{
  configurations.nixos.galactica.module = {
    config,
    pkgs,
    lib,
    ...
  }: let
    vars = config.media.config;
    secrets = config.sops.secrets;
    port = 8577;
    pia = config.constellation.pia;
    # rqbit's API, inside the PIA namespace (3030 is loki's).
    streamApiPort = 3031;
    # plab's GET-only stream listener, behind the plab-stream tailnet node.
    streamPort = 8578;
    # Scratch for streamed media: emptied on every plab-stream start and stop.
    streamDir = "${vars.storageDir}/media/Downloads/.plab-stream";
    # Its contents, not the dir: the sandbox cannot write the parent to recreate it.
    emptyScratch = "${pkgs.findutils}/bin/find ${streamDir} -mindepth 1 -delete";

    # Run as `plab …` with the daemon's environment, so a one-shot sees what the daemon sees.
    plab = pkgs.writeShellApplication {
      name = "plab";
      text = ''
        export PLAB_USERNAME_FILE="''${PLAB_USERNAME_FILE:-${secrets.plab-username.path}}"
        export PLAB_PASSWORD_FILE="''${PLAB_PASSWORD_FILE:-${secrets.plab-password.path}}"
        export PLAB_STATE_DIR="''${PLAB_STATE_DIR:-/var/lib/plab}"
        # Straight into the PIA namespace, never through the Authelia-gated
        # transmission vhost (see transmission-vpn.nix).
        export PLAB_TRANSMISSION_URL="http://${config.constellation.pia.namespaceAddress}:9091/transmission/rpc"
        # The path Prowlarr's `Vault` category produces too; a symlink to ../Vault.
        export PLAB_DOWNLOAD_DIR="${vars.storageDir}/media/Downloads/Vault"
        export PLAB_GAMES_DIR="${vars.storageDir}/media/Downloads/Games"
        export PLAB_STATIC_DIR="''${PLAB_STATIC_DIR:-${pkgs.plab.ui}}"
        export PLAB_EXCLUDE_FILE="''${PLAB_EXCLUDE_FILE:-${secrets.plab-exclude.path}}"
        export PLAB_FILTER_FILE="''${PLAB_FILTER_FILE:-${secrets.plab-filter.path}}"
        export PLAB_SOURCES_FILE="''${PLAB_SOURCES_FILE:-${secrets.plab-sources.path}}"
        export PLAB_SITE_FILE="''${PLAB_SITE_FILE:-${secrets.plab-site.path}}"
        export PLAB_OPENROUTER_KEY_FILE="''${PLAB_OPENROUTER_KEY_FILE:-${secrets.openrouter-api-key.path}}"
        export PLAB_GRAB_RULES_FILE="''${PLAB_GRAB_RULES_FILE:-${secrets.vault-grab-rules.path}}"
        export PLAB_PROWLARR_URL="http://127.0.0.1:9696"
        # Where the browser reaches Stash (the page links downloads to their scenes);
        # the daemon itself talks to Stash on localhost.
        export PLAB_STASH_WEB_URL="https://stash.${vars.domain}"
        # Read at run time: Prowlarr owns the key, so there is no second copy to drift.
        export PLAB_PROWLARR_CONFIG="${vars.configDir}/prowlarr/config.xml"
        # The stream engine, straight into the PIA namespace like Transmission.
        export PLAB_RQBIT_URL="http://${pia.namespaceAddress}:${toString streamApiPort}"
        export PLAB_STREAM_PUBLIC_URL="https://plab-stream.${vars.tsDomain}"
        exec ${pkgs.plab}/bin/plab "$@"
      '';
    };
  in {
    sops.secrets.plab-username.owner = vars.user;
    sops.secrets.plab-password.owner = vars.user;
    sops.secrets.plab-exclude.owner = vars.user;
    sops.secrets.plab-filter.owner = vars.user;
    sops.secrets.plab-sources.owner = vars.user;
    sops.secrets.plab-site.owner = vars.user;
    sops.secrets.openrouter-api-key.owner = vars.user;
    sops.secrets.vault-grab-rules.owner = vars.user;

    environment.systemPackages = [plab];

    # host: the default (the hostname) resolves to 127.0.0.2 here, and plab listens
    # on 127.0.0.1 only. Authelia-gated: no bypassAuth.
    media.services.plab = {
      inherit port;
      host = "127.0.0.1";
    };

    systemd.services.plab = let
      stash = "${config.virtualisation.oci-containers.backend}-stash.service";
    in {
      description = "plab: page, Stash identification, refresh, prune and grab";
      wantedBy = ["multi-user.target"];
      # Wants transmission so a start brings it up if it is down (it was, for hours,
      # after the 2026-10-31 activation panic); prune would otherwise fail every hour.
      after = ["network-online.target" "transmission.service" "plab-stream.service" stash "mnt-storage.mount"];
      wants = ["network-online.target" "transmission.service" "plab-stream.service" stash];
      requires = ["mnt-storage.mount"];
      serviceConfig = {
        ExecStart = "${plab}/bin/plab serve --bind 127.0.0.1 --port ${toString port} --stream-port ${toString streamPort}";
        User = vars.user;
        Group = vars.group;
        StateDirectory = "plab";
        UMask = "0077"; # state.db holds the tracker session
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # The stream engine's API, reachable from the host at the namespace address.
    vpnNamespaces.${pia.namespace}.portMappings = [
      {
        from = streamApiPort;
        to = streamApiPort;
        protocol = "tcp";
      }
    ];

    # rqbit for plab's Stream button: peer traffic inside the PIA namespace, outbound only
    # (Transmission keeps PIA's one forwarded port), nothing kept. PartOf plab, so a plab
    # restart empties it and the two never disagree about which streams exist.
    #
    # Why the sandbox: the portMappings above DNAT tcp/3031 into the namespace from any
    # interface, rqbit 8.1.1's API has no authentication, and its `POST /torrents` takes an
    # `output_folder`. So any LAN or tailnet host, or any container, could have rqbit write,
    # as media, anywhere media can write. Rather than a per-app firewall rule (this repo has
    # none), the unit can write only its scratch dir and its DHT cache: ProtectSystem=strict
    # makes everything else read-only, ProtectHome hides /home, PrivateTmp gives it its own
    # /tmp. An add aimed elsewhere fails with EROFS instead of landing in the library.
    systemd.services.plab-stream = {
      description = "plab-stream: rqbit streaming engine for plab (PIA namespace, no persistence)";
      wantedBy = ["multi-user.target"];
      partOf = ["plab.service"];
      before = ["plab.service"];
      after = ["mnt-storage.mount"];
      requires = ["mnt-storage.mount"];
      vpnConfinement = {
        enable = true;
        vpnNamespace = pia.namespace;
      };
      environment.XDG_CACHE_HOME = "/var/cache/plab-stream"; # rqbit's DHT state
      serviceConfig = {
        ExecStartPre = [
          # Privileged ("+", outside the sandbox): ReadWritePaths needs the dir to exist,
          # and the unit cannot create it under its read-only parent. Not a tmpfiles rule:
          # /mnt/storage is nofail, so boot-time tmpfiles can run before it is mounted and
          # create the dir on the root fs underneath it.
          "+${pkgs.coreutils}/bin/install -d -m 0750 -o ${vars.user} -g ${vars.group} ${streamDir}"
          emptyScratch
        ];
        # A stop or shutdown leaves no media behind either.
        ExecStopPost = "-${emptyScratch}";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.rqbit}/bin/rqbit"
          "--http-api-listen-addr ${pia.namespaceAddress}:${toString streamApiPort}"
          "--disable-tcp-listen"
          "--disable-upnp-port-forward"
          "server start --disable-persistence ${streamDir}"
        ];
        User = vars.user;
        Group = vars.group;
        CacheDirectory = "plab-stream"; # systemd keeps it writable under ProtectSystem
        ProtectSystem = "strict";
        # "-": the dir may not exist yet; the privileged ExecStartPre creates it, and each Exec command sets up its own namespace.
        ReadWritePaths = ["-${streamDir}"];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # VLC's way in: tailnet only, plab's GET-only stream listener, no Authelia.
    services.tsnsrv.services.plab-stream = {
      toURL = "http://127.0.0.1:${toString streamPort}";
      prefixes = ["/stream/"];
      stripPrefix = false;
      funnel = false;
    };
  };
}
