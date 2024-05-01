{
  lib,
  self,
  config,
  ...
}: {
  users.users.media = {
    uid = 5000;
    isSystemUser = true;
    group = "media";
  };

  users.groups.media.gid = 5000;
}
