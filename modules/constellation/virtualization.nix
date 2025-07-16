# Constellation virtualization module
#
# This module provides virtualization capabilities including libvirt/QEMU support.
# It's enabled by default but can be disabled on resource-constrained systems
# like routers where virtualization is not needed.
#
# Features:
# - libvirtd service for managing VMs
# - QEMU/KVM support
# - virt-manager and related tools
# - Proper permissions for virtualization
{
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  options.constellation.virtualization = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable virtualization support including libvirt and QEMU.
        This adds significant disk usage and is not needed on all systems.
      '';
      default = config.constellation.common.enable;
    };
  };

  config = lib.mkIf config.constellation.virtualization.enable {
    # Enable libvirtd service
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = false;
        swtpm.enable = true;
      };
    };

    # Add libvirt to system packages
    environment.systemPackages = with pkgs; [
      libvirt
      virt-manager
      qemu
    ];

    # Enable dconf for virt-manager
    programs.dconf.enable = true;

    # Add users to libvirtd group
    users.groups.libvirtd.members = ["root"];
  };
}
