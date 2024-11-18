{
  config,
  self,
  ...
}: {
  age.secrets."borg-passkey".file = "${self}/secrets/borg-passkey.age";
  age.secrets."hetzner".file = "${self}/secrets/hetzner.age";

  services.borgbackup.jobs.hetzner = {
    repo = "ssh://u393920@u393920.your-storagebox.de:23/./backups/storage";
    paths = [
      "/home"
      "/var/lib"
      "/var/data"
      "/root"
    ];
    exclude = [
      # very large paths
      "/var/lib/docker"
      "/var/lib/systemd"
      "/var/lib/libvirt"

      "/mnt/data/homes/*/.cache"
      "/mnt/data/homes/*/.nix-profile"
    ];
    extraCreateArgs = "--progress";
    environment = {
      BORG_RSH = "ssh -i ${config.age.secrets."hetzner".path}";
    };
    encryption = {
      mode = "repokey-blake2";
      passCommand = "cat ${config.age.secrets."borg-passkey".path}";
    };
    compression = "zstd";
    startAt = "monthly";
  };
}
