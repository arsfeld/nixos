# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
args @ {
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; {
  imports = [
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./networking.nix
    ./services.nix
    ./samba.nix
    (
      import ../../common/backup.nix (
        args
        // {repo = "e0i590z4@e0i590z4.repo.borgbase.com:repo";}
      )
    )
  ];

  # Console
  console = {
    font = "ter-132n";
    packages = with pkgs; [terminus_font];
    keyMap = "us";
  };

  # TTY
  services.kmscon = {
    enable = true;
    hwRender = true;
    extraConfig = ''
      font-name=MesloLGS NF
      font-size=14
    '';
  };

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "vhost_vsock"];
    supportedFilesystems = ["zfs"];

    # Plymouth
    consoleLogLevel = 0;
    initrd.verbose = false;
    plymouth.enable = true;
    kernelParams = ["quiet" "splash" "rd.systemd.show_status=false" "rd.udev.log_level=3" "udev.log_priority=3" "boot.shell_on_fail"];
  };

  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.displayManager.gdm.autoSuspend = false;
  services.xserver.desktopManager.gnome.enable = true;
  hardware.bluetooth.enable = true;

  # virtualisation = {
  #   lxd = {
  #     enable = true;
  #     recommendedSysctlSettings = true;
  #   };
  # };

  services.gnome.chrome-gnome-shell.enable = true;

  services.blueman.enable = true;
  services.flatpak.enable = true;

  programs.steam = {
    enable = true;
  };

  fonts.fonts = with pkgs; [
    meslo-lgs-nf
    (nerdfonts.override {fonts = ["FiraCode" "DroidSansMono" "CascadiaCode"];})
  ];

  # fileSystems."/mnt/data/media" = {
  #   device = "192.168.31.10:/mnt/data/media";
  #   fsType = "nfs";
  #   options = ["nfsvers=4.2" "nofail"];
  # };
  # fileSystems."/mnt/data/files" = {
  #   device = "192.168.31.10:/mnt/data/files";
  #   fsType = "nfs";
  #   options = ["nfsvers=4.2" "nofail"];
  # };
  # fileSystems."/mnt/data/homes" = {
  #   device = "192.168.31.10:/mnt/data/homes";
  #   fsType = "nfs";
  #   options = ["nfsvers=4.2" "nofail"];
  # };

  environment.systemPackages = with pkgs; [
    vim
    wget
    vscode-fhs
    gnome.gnome-software
    gnome.gnome-tweaks
  ];
}
