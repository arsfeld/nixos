{lib, ...}: {
  services.borgbackup.jobs = {
    "borgbase" = {
      paths = [
        "/var/lib"
        "/srv"
        "/home"
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
      repo = "k67n1w1o@k67n1w1o.repo.borgbase.com:repo";
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /root/borgbackup/passphrase";
      };
      environment.BORG_RSH = "ssh -i /root/borgbackup/ssh_key";
      extraCreateArgs = "--progress --verbose --stats";
      compression = "auto,zstd";
      startAt = "daily";
    };
  };
}
