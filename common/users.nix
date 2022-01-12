{ config, pkgs, ... }:
{
  users.users.arosenfeld = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "Alexandre Rosenfeld";
    extraGroups = [ "wheel" "docker" "lxd" "media" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w" ];
    uid = 1000;
  };
  users.groups.arosenfeld.gid = 1000;

  users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w" ];

  users.users.media.uid = 5000;
  users.users.media.isSystemUser = true;
  users.users.media.group = "media";
  users.groups.media.gid = 5000;
}
