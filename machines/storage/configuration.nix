# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
args @ {
  lib,
  pkgs,
  ...
}:
with lib; {
  imports = [
    ./variables.nix
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/acme.nix
    ../../common/users.nix
    ../../common/mail.nix
    ../../common/blocky.nix
    ../../common/sites/arsfeld.one.nix
    ./zfs.nix
    ./cloud-sync.nix
    ./users.nix
    ./samba.nix
    ./backup.nix
    ./services.nix
    ./services/backup.nix
    ./services/media.nix
  ];

  networking.hostName = "storage";
  networking.firewall.enable = false;

  nixpkgs.config.permittedInsecurePackages = [
    "nodejs-16.20.2"
  ];

  virtualisation.docker.storageDriver = "zfs";

  boot = {
    #loader.systemd-boot.enable = true;
    #loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "ip6_tables"];
    #supportedFilesystems = ["zfs"];
  };

  systemd.email-notify.mailFrom = "admin@arsfeld.one";
  systemd.email-notify.mailTo = "arsfeld@gmail.com";

  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "monthly";
  services.smartd = {
    enable = true;
    notifications.mail.enable = true;
    notifications.test = true;
  };

  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.userServices = true;
  };

  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override {enableHybridCodec = true;};
  };
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
    ];
  };

  services.vector = {
    enable = false;
    journaldAccess = true;
    settings = {
      "sources" = {
        "journald" = {
          type = "journald";
          current_boot_only = true;
        };
      };
      "sinks" = {
        # "logtail" = {
        #   type = "http";
        #   inputs = ["journald"];
        #   uri = "https://in.logtail.com/";
        #   encoding.codec = "json";
        #   request.headers.Authorization = "Bearer CkDXNhRmcRQ5nVX8qW8jsWfA";
        # };
        "axiom" = {
          "type" = "axiom";
          "inputs" = [
            "journald"
          ];
          "dataset" = "storage";
          "token" = "xaat-ca79c6c6-ba0b-4ac0-a201-61f8f9690f90";
        };
      };
    };
  };
}
