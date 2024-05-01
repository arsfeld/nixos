{
  config,
  pkgs,
  self,
  ...
}: {
  age.secrets.cloudflare = {
    file = "${self}/secrets/cloudflare.age";
    owner = "acme";
    group = "acme";
  };

  security.acme.acceptTerms = true;

  security.acme.defaults = {
    email = "arsfeld@gmail.com";
    dnsResolver = "1.1.1.1:53";
    dnsProvider = "cloudflare";
    credentialsFile = config.age.secrets.cloudflare.path;
  };
}
