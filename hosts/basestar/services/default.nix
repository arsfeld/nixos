{
  # Failover services that ran here while galactica was down (cloudflared
  # connector, vault, yarr, search, ntfy, finance-tracker) were retired on
  # 2026-07-25 after galactica came back online and their data was migrated
  # back. Keeping them running split Cloudflare tunnel traffic between the
  # two hosts and caused split-brain writes to the stateful services.
  imports = [
    ./blog.nix
    ./gatus.nix
    ./niks3.nix
    ./planka.nix
    ./plausible.nix
    ./radicle.nix
    ./siyuan.nix
    ./sillytavern.nix
    ./webui.nix
  ];
}
