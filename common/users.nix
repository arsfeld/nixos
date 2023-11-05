{
  config,
  pkgs,
  ...
}: {
  programs.zsh.enable = true;

  users.users.arosenfeld = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Alexandre Rosenfeld";
    extraGroups = ["wheel" "docker" "lxd" "media" "libvirtd" "networkmanager"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICobaxx3CHHrOxWLW9Sol7WSaUyLDmG+un2g5K1ongBK alexandre.rosenfeld@ubisoft.com"
    ];
    hashedPassword = "$6$Csmhna5YUVoHnZ/S$lrSk0wko.Z/oL.Omf2jAdLc/mSpZsrw8sOXlknmfdHEjMopP7hESNk9PCArGBnZKm566Fo2QoubQWt0SLjbng.";
    uid = 1000;
  };
  users.groups.arosenfeld.gid = 1000;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];

  users.users.media.uid = 5000;
  users.users.media.isSystemUser = true;
  users.users.media.group = "media";
  users.groups.media.gid = 5000;
}
