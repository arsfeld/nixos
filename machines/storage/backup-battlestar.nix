{
  lib,
  repo,
  ...
}: {
  services.borgbackup.jobs = {
    "battlestar" = {
      paths = [
        "/home"
      ];
      exclude = [
        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      repo = "borg@battlestar:storage";
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /root/borgbackup/passphrase";
      };
      environment.BORG_RSH = "ssh -i /root/borgbackup/ssh_key";
      extraCreateArgs = "--progress --verbose --stats";
      compression = "auto,zstd";
      startAt = "weekly";
    };
  };
}
