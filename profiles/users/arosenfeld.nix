{
  lib,
  pkgs,
  config,
  self,
  ...
}: {
  users.users.arosenfeld = {
    isNormalUser = true;
    shell = pkgs.fish;
    description = "Alexandre Rosenfeld";
    extraGroups = ["users" "wheel" "docker" "lxd" "media" "libvirtd" "networkmanager" "incus-admin"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKdOiSH7TgoulL4YasuXaeWC/j3BjGUi9v6168BifciA alexandre.rosenfeld@issuerdirect.com"
    ];
    hashedPassword = "$6$Csmhna5YUVoHnZ/S$lrSk0wko.Z/oL.Omf2jAdLc/mSpZsrw8sOXlknmfdHEjMopP7hESNk9PCArGBnZKm566Fo2QoubQWt0SLjbng.";
    uid = 1000;
  };
  users.groups.arosenfeld.gid = 1000;
}
