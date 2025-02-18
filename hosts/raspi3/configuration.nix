{
  config,
  pkgs,
  self,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "raspi3";
  time.timeZone = "America/Toronto";

  services.tailscale.enable = true;

  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";

  services.tsnsrv = {
    enable = true;
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.age.secrets.tailscale-key.path;
    };
    services = {
      octoprint = {
        toURL = "http://127.0.0.1:5000";
        funnel = true;
      };
    };
  };

  # nixpkgs.overlays = [(self: super: {
  #   octoprint = super.octoprint.override {
  #     packageOverrides = pyself: pysuper: {
  #       octoprint-prettygcode = pyself.buildPythonPackage rec {
  #         pname = "PrettyGCode";
  #         version = "1.2.4";
  #         src = self.fetchFromGitHub {
  #           owner = "Kragrathea";
  #           repo = "OctoPrint-PrettyGCode";
  #           rev = "v${version}";
  #           sha256 = "sha256-q/B2oEy+D6L66HqmMkvKfboN+z3jhTQZqt86WVhC2vQ=";
  #         };
  #         propagatedBuildInputs = [ pysuper.octoprint ];
  #         doCheck = false;
  #       };
  #     };
  #   };
  # })];

  services.octoprint = {
    enable = true;
    plugins = plugins: with plugins; [themeify stlviewer];
  };

  #virtualisation.podman.dockerSocket.enable = true;

  # virtualisation.oci-containers = {
  #   backend = "podman";
  #   containers = {
  #     homeassistant = {
  #       volumes = ["/etc/home-assistant:/config"];
  #       environment.TZ = "America/Toronto";
  #       image = "ghcr.io/home-assistant/home-assistant:stable";
  #       extraOptions = [
  #         "--network=host"
  #         "--privileged"
  #         "--label"
  #         "io.containers.autoupdate=image"
  #       ];
  #     };
  #   };
  # };

  # systemd.timers.podman-auto-update = {
  #   description = "Podman auto-update timer";
  #   partOf = ["podman-auto-update.service"];
  #   wantedBy = ["timers.target"];
  #   timerConfig.OnCalendar = "weekly";
  # };

  services.openssh.enable = true;
  networking.firewall.enable = false;

  system.stateVersion = "23.05";
}
