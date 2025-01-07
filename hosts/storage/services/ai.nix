{
  config,
  pkgs,
  lib,
  ...
}: let
  farfalleDockerfile = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rashadphz/farfalle/main/standalone.Dockerfile";
    sha256 = lib.fakeHash;
  };

  farfalleImage = pkgs.dockerTools.buildImage {
    name = "farfalle";
    tag = "latest";
    contents = [farfalleDockerfile];
    config = {
      Cmd = ["/bin/sh" "-c" "docker build -f ${farfalleDockerfile} . && docker run farfalle"];
    };
  };
in {
  services.ollama = {
    enable = true;
    loadModels = ["llama3.1"];
    host = "0.0.0.0";
    environmentVariables = {
      OLLAMA_ORIGINS = "https://ollama-api.arsfeld.one";
    };
  };

  services.nextjs-ollama-llm-ui = {
    enable = true;
    port = 30198;
    hostname = "0.0.0.0";
    ollamaUrl = "https://ollama-api.arsfeld.one";
  };

  # systemd.services.farfalle-container = {
  #   description = "Farfalle Container";
  #   after = [ "docker.service" ];
  #   requires = [ "docker.service" ];
  #   wantedBy = [ "multi-user.target" ];
  #   serviceConfig = {
  #     ExecStart = "${pkgs.docker}/bin/docker run --rm --name farfalle ${farfalleImage.imageName}";
  #     ExecStop = "${pkgs.docker}/bin/docker stop farfalle";
  #     Restart = "always";
  #     RestartSec = "10s";
  #   };
  # };
}
