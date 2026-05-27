{pkgs, ...}: let
  btrfsConvertToSubvolume = pkgs.writeShellApplication {
    name = "btrfs-convert-to-subvolume";
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      util-linux # stat
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./btrfs-convert-to-subvolume.py} "$@"
    '';
  };
in {
  environment.systemPackages = [btrfsConvertToSubvolume];
}
