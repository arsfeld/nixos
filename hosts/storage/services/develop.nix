{
  config,
  self,
  ...
}: let
  vars = config.mediaServices;
  ports = (import "${self}/common/services.nix" {}).ports;
in {
  services.openvscode-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    port = ports.code;
    withoutConnectionToken = true;
  };

  services.gitea = {
    enable = true;
    appName = "My awesome Gitea server";
    settings = {
      server = {
        ROOT_URL = "https://gitea.${vars.domain}/";
        HTTP_PORT = 3001;
        DOMAIN = "gitea.${vars.domain}";
      };
      actions = {
        ENABLED = "true";
      };
    };
  };
}
