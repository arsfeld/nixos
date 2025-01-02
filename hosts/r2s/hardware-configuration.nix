{
  config,
  pkgs,
  lib,
  ...
}: {
  hardware.deviceTree.name = "rockchip/rk3328-nanopi-r2s.dtb";
  # hardware.deviceTree.filter = "*rk3328-nanopi-r2s.dtb";
  # hardware.deviceTree.overlays = [{
  #   name = "sysled";
  #   dtsFile = ./files/sysled.dts;
  # }];

  # NanoPi R2S's DTS has not been actively updated, so just use the prebuilt one to avoid rebuilding
  hardware.deviceTree.package = pkgs.lib.mkForce (
    pkgs.runCommand "dtbs-nanopi-r2s" {} ''
      install -TDm644 ${./files/rk3328-nanopi-r2s.dtb} $out/rockchip/rk3328-nanopi-r2s.dtb
    ''
  );

  hardware.firmware = [
    (
      pkgs.runCommand
      "linux-firmware-r8152"
      {}
      ''
        install -TDm644 ${./files/rtl8153a-4.fw} $out/lib/firmware/rtl_nic/rtl8153a-4.fw
        install -TDm644 ${./files/rtl8153b-2.fw} $out/lib/firmware/rtl_nic/rtl8153b-2.fw
      ''
    )
  ];

  fileSystems = {
    # "/boot" = {
    #   device = "/dev/disk/by-label/NIXOS_BOOT";
    #   fsType = "ext4";
    # };
    # "/" = {
    #   device = "/dev/disk/by-label/NIXOS_SD";
    #   fsType = "f2fs";
    #   options = ["compress_algorithm=zstd:6" "compress_chksum" "atgc" "gc_merge" "lazytime"];
    # };
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };
  };

  boot = {
    loader = {
      timeout = 1;
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        configurationLimit = 5;
      };
    };
    kernelPackages = pkgs.linuxPackages;
    kernelParams = [
      "console=ttyS2,1500000"
      "earlycon=uart8250,mmio32,0xff130000"
      "mitigations=off"
    ];
    initrd = {
      includeDefaultModules = false;
      kernelModules = ["ledtrig-netdev"];
    };
    blacklistedKernelModules = ["hantro_vpu" "drm" "lima" "videodev"];
    kernelModules = ["ledtrig-netdev"];
    tmp.useTmpfs = true;
  };

  boot.kernel.sysctl = {
    "vm.vfs_cache_pressure" = 10;
    "vm.dirty_ratio" = 50;
    "vm.swappiness" = 20;
  };

  powerManagement.cpuFreqGovernor = "schedutil";

  services.lvm.enable = false;

  services.timesyncd.extraConfig = ''
    PollIntervalMinSec=16
    PollIntervalMaxSec=180
    ConnectionRetrySec=3
  '';
  systemd.additionalUpstreamSystemUnits = [
    "systemd-time-wait-sync.service"
  ];
  services.fake-hwclock.enable = true;
  networking.timeServers = [
    "0.ca.pool.ntp.org"
    "1.ca.pool.ntp.org"
    "2.ca.pool.ntp.org"
  ];

  systemd.services."wait-system-running" = {
    description = "Wait system running";
    serviceConfig = {Type = "simple";};
    script = ''
      systemctl is-system-running --wait
    '';
  };

  systemd.services."setup-net-leds" = {
    description = "Setup network LEDs";
    unitConfig = {DefaultDependencies = "no";};
    serviceConfig = {Type = "simple";};
    wantedBy = ["sysinit.target"];
    script = ''
      cd /sys/class/leds/nanopi-r2s:green:lan
      echo netdev > trigger
      echo 1 | tee link tx rx >/dev/null
      echo intern0 > device_name

      cd /sys/class/leds/nanopi-r2s:green:wan
      echo netdev > trigger
      echo 1 | tee link tx rx >/dev/null
      echo extern0 > device_name
    '';
  };
  systemd.services."setup-sys-led" = {
    description = "Setup booted LED";
    requires = ["wait-system-running.service"];
    after = ["wait-system-running.service"];
    wantedBy = ["multi-user.target"];
    script = ''
      echo default-on > /sys/class/leds/nanopi-r2s:red:sys/trigger
    '';
  };
}
