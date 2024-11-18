{config, ...}: let
  vars = config.vars;
in {
  services.openvscode-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    port = 3434;
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
