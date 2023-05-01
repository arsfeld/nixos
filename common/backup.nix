{
  lib,
  repo,
  ...
}: {
  services.borgbackup.jobs = {
    "borgbase" = {
      paths = [
        "/var/lib"
        "/var/data"
        "/srv"
        "/root"
      ];
      exclude = [
        # very large paths
        "/var/lib/docker"
        "/var/lib/systemd"
        "/var/lib/libvirt"

        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      repo = repo;
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /root/borgbackup/passphrase";
      };
      environment.BORG_RSH = "ssh -i /root/borgbackup/ssh_key";
      extraCreateArgs = "--progress --verbose --stats";
      compression = "auto,zstd";
      startAt = "*-*-* 04:30:00";
    };
  };
}
