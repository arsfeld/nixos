# cylon-link: a Valve Steam Link running NixOS as an always-on helper.
# It boots through Valve's firmware and kexec; see ./boot and CLAUDE.md.
{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware.nix
    ./boot
    ./image.nix
  ];

  networking.hostName = "cylon-link";

  constellation.common.minimal = true;
  constellation.sops.enable = true;
  # Too heavy for 500 MB of RAM and a cross build.
  constellation.virtualization.enable = false;
  constellation.netdataClient.enable = false;
  # Determinate publishes no armv7l build, so use nixpkgs' Nix.
  determinate.enable = false;
  # fish does not cross-compile: its build-time xtask helper links for the
  # build platform against the armv7l pcre2 ("skipping incompatible
  # libpcre2-8.so"). Both settings go, since nixpkgs asserts a fish login
  # shell has programs.fish enabled.
  programs.fish.enable = lib.mkForce false;
  users.users.arosenfeld.shell = lib.mkForce pkgs.bashInteractive;

  # Closure size: the device only runs what raider built for it.
  # Wired only; Wi-Fi is out of scope, so no firmware blobs.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  # The device never evaluates Nix, so it needs no flake-input sources.
  nix.registry = lib.mkForce {};
  nix.nixPath = lib.mkForce [];
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  # `just deploy` runs nixos-rebuild on raider; the target only runs nix-env
  # and the generation's switch-to-configuration.
  system.tools.nixos-rebuild.enable = false;
  # Cross-compiled msmtpq scripts get the build platform's bash as their
  # interpreter, which pulls x86_64 glibc into the closure. Nothing here uses
  # msmtpq; send-email-event and sendmail call the msmtp binary.
  nixpkgs.overlays = [(_: prev: {msmtp = prev.msmtp.override {withScripts = false;};})];
  # nixpkgs' avahi unit re-allows setgroups and setresuid after ~@privileged,
  # but 32-bit ARM glibc calls setgroups32 and setresuid32, which stay
  # blocked, so seccomp kills the daemon with SIGSYS at startup.
  systemd.services.avahi-daemon.serviceConfig.SystemCallFilter = ["setgroups32 setresuid32"];

  # Tailscale is logged in by hand, so a reflash needs one interactive login:
  # `tailscale up --hostname=cylon-link --advertise-tags=tag:server`, the tag
  # every other host carries. The shared tailscale-key is no substitute: it is
  # the OAuth client tsnsrv uses to mint tag:service nodes.
  # Unlike the rest of the fleet, Tailscale SSH is off and port 22 on
  # tailscale0 is this host's OpenSSH. On this one slow core, tailscaled's SSH
  # server drops the exit status of fast commands on multiplexed connections
  # (6 of 20 over `ControlMaster=auto`, 0 of 20 on galactica), and
  # nixos-rebuild multiplexes, then reads the lost status as a failed check
  # and aborts the deploy.
  services.tailscale.extraSetFlags = lib.mkForce ["--ssh=false"];
  # tailscaled otherwise defaults to iptables, and nixpkgs' iptables is the
  # nf_tables variant, whose MARK and MASQUERADE targets need xtables compat
  # modules this kernel does not build. Native nftables needs only what
  # hardware.nix already adds.
  systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

  # The device never compiles. A path missing from cache.arsfeld.dev should
  # fail the deploy, not start a build on one Cortex-A9 core.
  nix.settings.max-jobs = 0;

  system.stateVersion = "26.05";
}
