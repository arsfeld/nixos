{
  configurations.nixos.blackbird.module = {
    config,
    pkgs,
    ...
  }: let
    # Defined in _dgpu-power.nix; nvidia.nix makes the identical call for its
    # Executor command. Listed here so systemPackages keeps its order.
    dgpu-power = pkgs.callPackage ./_dgpu-power.nix {nvidia = config.hardware.nvidia.package;};
  in {
    # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
    # publishes). owner + mode let the user-mode script read it directly.
    sops.secrets."ntfy-publisher-env" = {
      sopsFile = ../../../secrets/sops/ntfy-client.yaml;
      owner = "arosenfeld";
      mode = "0400";
    };

    # Enable constellation modules
    constellation = {
      desktop = {
        # Experimental. "gnome" is the way back: the GNOME settings below, and
        # the gsettings overrides in power.nix, are inert under Pantheon and
        # kept for that switch.
        variant = "pantheon";
        pantheon.dockStacks = [
          {
            source = "~/Downloads";
            view = "fan";
            sort = "date-added";
          }
          {
            source = "applications";
            display = "grid";
          }
        ];
        gnome.monitorControl.enable = true;
        gnome.gpuMonitor.enable = true;
        gnome.theme = {
          gtk = "Yaru-purple-dark";
          icon = "Yaru-purple";
        };
      };
      gaming = {
        cpuVendor = "amd";
      };
    };

    # Basic system configuration
    networking.hostName = "blackbird";

    # Ventoy bundles an older GTK3 flagged insecure by nixpkgs
    nixpkgs.config.permittedInsecurePackages = ["ventoy-gtk3-1.1.12"];

    # Additional packages
    environment.systemPackages = with pkgs; [
      powertop
      acpi # Battery status monitoring
      easyeffects # Audio enhancement for G14 speakers
      alsa-utils # Audio utilities
      librepods # Open-source AirPods client
      ventoy-full-gtk # Multiboot USB creator (CLI + GTK GUI, all plugins)
      dgpu-power # dGPU power-limit readout, also driven by Executor in nvidia.nix
    ];

    # Bootloader: systemd-boot. rEFInd ran here from May to September 2026 and
    # ended with the machine unable to reach NixOS at all: on 2026-09-11 its menu
    # painted a blank background and never drew an entry or honoured its timeout,
    # while its own refind.log reached "Entering main loop" cleanly on every
    # attempt, and the kernels and initrds it would have launched were
    # byte-identical to cache.arsfeld.dev. The cause was never isolated. systemd-boot
    # has no theme, icons or pointer handling to fail, and it finds Windows'
    # \EFI\Microsoft\Boot\bootmgfw.efi on this same ESP by itself, so dual boot
    # needs no stanza.
    #
    # Switching from another bootloader needs `nixos-rebuild --install-bootloader`
    # once; without it the builder aborts because it finds no systemd-boot on the
    # ESP. That run creates the "Linux Boot Manager" firmware entry, but on this
    # machine (2026-09-11, systemd 260.2) it was appended *last* in BootOrder,
    # behind the old entries, so the firmware kept launching whatever was first.
    # Check `efibootmgr` afterwards and move it to the front with `efibootmgr -o`.
    #
    # configurationLimit is what keeps the ESP from filling. /boot here *is* the
    # 500 MB ESP (see disko-config.nix), and every listed generation's kernel
    # (~14 MB) and initrd (~71 MB) is copied into /boot/EFI/nixos. Unset, every
    # generation ever built is listed; under rEFInd the copies reached ~384 MB of
    # the 524 MB. The builder copies before it prunes, so a full ESP fails
    # mid-activation rather than cleanly.
    boot.loader.systemd-boot = {
      enable = true;
      configurationLimit = 4;
    };
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.timeout = 10;

    # Kernel parameters for performance and power management
    boot.kernelParams = [
      # Disable zswap - conflicts with zram (double compression wastes RAM)
      "zswap.enabled=0"
      "mitigations=off"
      "splash"
      "quiet"
      "udev.log_level=0"
      # i915 frame buffer + panel self-refresh: iGPU-only, safe for dGPU
      "i915.enable_fbc=1"
      "i915.enable_psr=2"
      "nmi_watchdog=0"
      # Use the active AMD P-state driver so power-profiles-daemon can steer
      # EPP directly. Without this the kernel falls back to acpi-cpufreq and PPD
      # only flips platform_profile, leaving CPU at a fixed governor.
      "amd_pstate=active"
      # Note: pcie_aspm=force + pcie_aspm.policy=powersupersave were removed so
      # TLP's PCIE_ASPM_ON_AC can do per-AC tuning instead. Removing them did
      # NOT fix the dGPU's P5 / 30 W lock, which the old comment here claimed:
      # ASPM now reads Disabled on both link ends and the link still trains at
      # Gen 2 x8. See hardware-configuration.nix for the measured ceiling.
    ];

    # Use NetworkManager for network management (better for laptops)
    networking.networkmanager.enable = true;
    networking.useDHCP = false;

    # Add user to networkmanager group for network management
    users.users.arosenfeld.extraGroups = ["networkmanager"];

    # Incus container management (in addition to libvirt from constellation.virtualization)
    virtualisation.incus = {
      enable = true;
      ui.enable = true;
    };

    # Disable firewall for development
    networking.firewall.enable = false;

    # This value determines the NixOS release from which the default
    # settings for stateful data, like file locations and database versions
    # on your system were taken. It's perfectly fine and recommended to leave
    # this value at the release version of the first install of this system.
    system.stateVersion = "23.11";
  };
}
