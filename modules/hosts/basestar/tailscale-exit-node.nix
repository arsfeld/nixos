# basestar as the tailnet's exit node (offered in raider's Wingpanel indicator,
# packages/wingpanel-indicator-tailscale).
#
# The advertisement used to be a hand-set pref with nothing behind it, and
# routing through it took raider offline (2026-11-01). There were two faults.
# IPv6 forwarding was off while `::/0` was advertised. And none of tailscaled's
# own ts-forward/ts-postrouting chains were left in `ip filter`/`ip nat`. Those
# tables are shared with k3s (flannel, kube-router, through iptables-nft), and
# tailscaled installs its chains only when it starts, so nothing puts them back.
# Without the masquerade, forwarded packets leave with a 100.x source, which
# Oracle's VCN drops.
#
# So the masquerade lives in networking.nat's own `nixos-nat` tables, which
# nothing else on this host writes to, rather than relying on tailscaled's
# chains. Forwarding needs no allow rule: every forward hook here is policy
# accept (filterForward = false, see k3s.nix).
#
# IPv6 forwarding does not cost basestar its IPv6 default route: the kernel
# takes no RAs on enp0s6 (accept_ra = 0), and dhcpcd, which does, never checks
# the forwarding sysctl.
{
  configurations.nixos.basestar.module = {
    services.tailscale = {
      # Forwarding sysctls for IPv4 and IPv6, and loose reverse-path filtering.
      useRoutingFeatures = "server";
      extraSetFlags = ["--advertise-exit-node"];
    };

    networking.nat = {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = ["tailscale0"];
      externalInterface = "enp0s6";
    };
  };
}
