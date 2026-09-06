# iroh relay for mydia (cae1-1.relay.mydia.dev)
#
# Mydia's clients are compiled with this hostname as their default relay
# (lib/mydia/p2p/server.ex and player/lib/core/p2p/p2p_service.dart), so the
# name is load-bearing for every install in the field. It previously ran on the
# can-1 k3s cluster; see iroh-relay-README.md for the move and the version pin.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.mydia-iroh-relay;
  backend = config.virtualisation.oci-containers.backend;

  # Pinned by digest as well as tag: a re-published tag cannot swap the binary
  # underneath us. Held back from v1.0.3, whose published image is a static musl
  # build carrying noq-udp 1.1.0 and panics on the FIRST received datagram
  # (n0-computer/noq#774). Run iroh-relay-verify-image.sh before changing this;
  # a plain boot test cannot catch that bug.
  #
  # The digest pin also neutralises modules/constellation/podman.nix's daily
  # podman-image-pull timer, which restarts any oci-container whose freshly
  # pulled image differs from the running one and has no opt-out for this
  # container. Pulling a digest can only ever yield the same image, so that
  # timer is a permanent no-op here. Relaxing the pin back to a floating tag
  # re-arms daily auto-upgrade on a service with the v1.0.3 crash history.
  image = "n0computer/iroh-relay:v1.0.0@sha256:0124f8c335d9ad6618db13dc580b597ad5f1be0c987b6742696f4c1f5e325720";

  # https_bind_addr and quic_bind_addr belong inside [tls]; metrics is
  # metrics_bind_addr, not metrics_addr. The k8s ConfigMap this replaces had all
  # three wrong, and serde ignores unknown fields silently, so the defaults it
  # fell back to happened to match. They do not match here: a top-level
  # quic_bind_addr would leave QUIC on 127.0.0.1 and address discovery dead with
  # nothing in the log.
  configToml = pkgs.writeText "iroh-relay-config.toml" ''
    enable_relay = true
    enable_quic_addr_discovery = true
    http_bind_addr = "127.0.0.1:${toString cfg.httpPort}"
    metrics_bind_addr = "127.0.0.1:${toString cfg.metricsPort}"

    [tls]
    cert_mode = "Manual"
    manual_cert_path = "/certs/fullchain.pem"
    manual_key_path = "/certs/key.pem"
    # Documented as the certificate hostname for LetsEncrypt mode, and inert
    # under Manual, where the certificate files decide which names are served.
    # Kept for accuracy; it gates nothing.
    hostname = "${cfg.domain}"
    https_bind_addr = "127.0.0.1:${toString cfg.httpsPort}"
    quic_bind_addr = "0.0.0.0:${toString cfg.quicPort}"
  '';
in {
  options.services.mydia-iroh-relay = {
    enable = lib.mkEnableOption "iroh relay for mydia";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "cae1-1.relay.mydia.dev";
      description = "Public hostname. Compiled into mydia clients; do not change.";
    };

    stagingDomain = lib.mkOption {
      type = lib.types.str;
      default = "cae1-2.relay.mydia.dev";
      description = ''
        Second name carried on the same certificate, used to verify the relay
        before cae1-1 is pointed here. Safe to keep afterwards.
      '';
    };

    httpsPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Loopback port for the relay's HTTPS socket, behind Caddy.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8480;
      description = ''
        Loopback port for the relay's HTTP socket. With [tls] set this serves
        only the captive portal, and it has never been publicly reachable.
      '';
    };

    quicPort = lib.mkOption {
      type = lib.types.port;
      default = 7842;
      description = "Public UDP port for QUIC address discovery.";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9090;
      description = "Loopback port for the relay's Prometheus metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    # DNS-01, so this certificate can be issued while can-1 still serves
    # cae1-1: no HTTP challenge has to reach this host for a name it does not
    # yet own. cert_mode = "Manual" reads the files once at startup, which is
    # what makes reloadServices load-bearing rather than a nicety.
    security.acme.certs.${cfg.domain} = {
      extraDomainNames = [cfg.stagingDomain];
      reloadServices = ["${backend}-iroh-relay.service"];
    };

    virtualisation.oci-containers.containers.iroh-relay = {
      inherit image;
      cmd = ["--config-path" "/config/config.toml"];
      volumes = [
        "${configToml}:/config/config.toml:ro"
        "/var/lib/acme/${cfg.domain}:/certs:ro"
      ];
      # Host networking so the QUIC address-discovery server observes real
      # client addresses. Reporting the address it sees is the entire point of
      # that service, and a DNAT'd source would make it report the wrong one.
      extraOptions = ["--network=host"];
    };

    # acme-<cert>.service, not the acme-finished-<cert>.target that older
    # guides use: NixOS 25.11 removed that target, and systemd treats After=
    # and Wants= on a unit that does not exist as silently satisfied, so the
    # stale name looks like an ordering guard while enforcing nothing. This
    # mirrors what nixpkgs' own Caddy module does for its vhost certificates.
    systemd.services."${backend}-iroh-relay" = {
      after = ["acme-${cfg.domain}.service"];
      wants = ["acme-${cfg.domain}.service"];
    };

    services.caddy.virtualHosts."${cfg.domain}, ${cfg.stagingDomain}" = {
      useACMEHost = cfg.domain;
      extraConfig = ''
        # Upstream is https:// because the relay serves its services on the
        # HTTPS socket whenever [tls] is set, and [tls] is mandatory for QUIC
        # address discovery. The relay holds a real certificate for this name,
        # so this verifies against the system roots rather than skipping.
        reverse_proxy https://127.0.0.1:${toString cfg.httpsPort} {
          transport http {
            tls_server_name ${cfg.domain}
          }
        }
      '';
    };

    # The OCI VCN security list needs a matching UDP 7842 ingress rule. Both are
    # required, and the OCI one is invisible from inside this instance.
    networking.firewall.allowedUDPPorts = [cfg.quicPort];
  };
}
