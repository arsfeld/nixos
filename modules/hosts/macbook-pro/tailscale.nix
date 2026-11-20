# Start the Tailscale app at login once the network is up, instead of its own
# "Launch at login" setting. Two upstream bugs, both diagnosed on the Pro on
# 2026-11-20 from the unified log:
#
# - tailscale/tailscale#22166: on macOS 27 a never-registered login helper
#   reports SMAppService status .notFound, Tailscale treats that as fatal and
#   never calls register(), so the toggle fails ("Could not find the launch
#   daemon"). The Air works only because its helper was registered in 2025,
#   under macOS 15.
# - tailscale/tailscale#21753: an app started before Wi-Fi is up has its first
#   tunnel start fail ("No network available"); macOS restarts the tunnel and
#   reports it connected, but the app's IPN bus keeps failing and the menu says
#   "not connected" until a manual reconnect.
#
# So: wait for a default route, then start the app. If macOS's window restore
# already launched it early, quit it first, but only shortly after boot, so a
# reload of this agent during a later darwin-rebuild never bounces a healthy
# connection.
{
  configurations.darwin.macbook-pro.module = {pkgs, ...}: let
    script = pkgs.writeShellScript "tailscale-at-login" ''
      for _ in $(seq 150); do
        /sbin/route -n get default >/dev/null 2>&1 && break
        sleep 2
      done
      sleep 15
      boot=$(/usr/sbin/sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
      if [ $(( $(date +%s) - boot )) -lt 600 ] && /usr/bin/pgrep -xq Tailscale; then
        echo "$(date) quitting the early-launched app"
        /usr/bin/pkill -x Tailscale
        sleep 3
      fi
      echo "$(date) starting Tailscale"
      /usr/bin/open -g -a /Applications/Tailscale.app
    '';
  in {
    launchd.user.agents.tailscale-at-login.serviceConfig = {
      ProgramArguments = ["${script}"];
      RunAtLoad = true;
      StandardOutPath = "/tmp/tailscale-at-login.log";
      StandardErrorPath = "/tmp/tailscale-at-login.log";
    };
  };
}
