{
  config,
  self,
  ...
}: let
  vars = config.media.config;
in {
  services.code-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    port = 4444;
    auth = "none";
    proxyDomain = "code.${vars.domain}";
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
