# NVIDIA dGPU: the 30 W clamp workaround, its panel readouts, and the resume VT fix.
{
  configurations.nixos.blackbird.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Astra Monitor addresses GPUs by the PCI fields it parses out of `lspci -nnk`
    # and compares domain/bus/slot/vendorId/productId. For the dGPU at 01:00.0
    # [10de:2191] that is domain "0000:01", bus "00", slot "0" -- its field names
    # are shifted one place from the usual domain:bus:device.function.
    dgpu = {
      domain = "0000:01";
      bus = "00";
      slot = "0";
      vendorId = "10de";
      productId = "2191";
    };

    dgpu-power = pkgs.callPackage ./_dgpu-power.nix {nvidia = config.hardware.nvidia.package;};
  in {
    # nvidia-persistenced stays off. It is a headless-compute tool -- it keeps the
    # driver from deinitialising between CUDA jobs -- and nothing here needs that.
    # gnome-shell holds /dev/nvidia0 for the whole session anyway, so the driver
    # teardown its old comment worried about cannot happen.
    #
    # It was briefly switched back on under the theory that it PINS whatever power
    # budget exists when it starts, and so would hold the 60 W that
    # nvidia-unclamp-tgp establishes. That theory is falsified: with persistence
    # mode off, 60 W held across an idle GPU, an opened+closed Vulkan context, an
    # opened+closed OpenCL context, display-manager starting and gnome-shell
    # taking the device, and a full gamemode activation.
    #
    # Nor is it the cause of the clamp: booted with it false and the unclamp unit
    # masked, and the dGPU still came up at 30 W.
    hardware.nvidia.nvidiaPersistenced = false;

    # The dGPU comes up clamped to 30 W -- half its own 60 W VBIOS default, and
    # well under the 65 W this chassis is rated for with ROG Boost. Under that
    # clamp the driver holds perf level 1 of 3, which pins memory to 810 MHz
    # against a 6001 MHz spec. Measured effect: 26.2 GB/s of a ~288 GB/s bus, and
    # SW Power Cap active continuously in-game while the core sheds clock to fit.
    #
    # Reloading the nvidia modules once clears it. Measured immediately after,
    # same machine, same session: 60 W enforced, 6001 MHz memory, P0, and clpeak
    # global memory bandwidth 243 GB/s -- a 9.3x improvement, and ~85% of
    # theoretical, which is normal efficiency.
    #
    # Two things NOT to re-derive:
    #   - The NVRM "PlatformRequestHandler failed to get target temp / platform
    #     power mode from SBIOS" errors fire on the boot load AND on this reload,
    #     which succeeds. So they are correlated, not causal. Do not chase them
    #     expecting the clamp to move. (Cause: this board has no NVPCF at all and
    #     its legacy ACPI GPS handler is a stub -- CTGP, the Configurable-TGP
    #     grant, is never assigned anywhere in the DSDT or any of the 10 SSDTs.)
    #   - nvidia-smi -pl / -lmc are refused by the driver on this consumer mobile
    #     part, and GPUPowerMizerMode reads back 0 after being set. Neither is a
    #     lever here; the module reload is.
    #
    # Isolated by experiment -- the reload itself is the operative step, so do not
    # "simplify" this into a settings tweak:
    #   - Not nvidiaPersistenced. Booted with it false and this unit masked: still
    #     30 W. It is off, and not needed to hold the result either.
    #   - Not lact. Its config carries no power cap (current_profile: null), and
    #     60 W survives lactd restarting.
    #   - Not supergfxd. It starts at ~10.2 s, after the driver initialised at
    #     8.6 s and after the SBIOS errors at 9.8 s, so it is downstream of the
    #     clamp. (It does set the dGPU's runtime PM to Auto and tries to start
    #     nvidia-powerd, which fails -- expected, this board has no NVPCF.)
    #   - Not a warm-up effect. The reload was measured working at 52 s uptime.
    #
    # KNOWN LIMITATION -- this unit is not the whole fix. The 60 W it establishes
    # at boot has been observed reverting to 30 W later in a session: one boot ran
    # the unit at 12 s and read 60 W at 26 s, then Steam started at 62 s and Forza
    # at 105 s, and by ~200 s the dGPU was back to 30 W with SW Power Cap active,
    # where it stayed for the whole play session.
    #
    # The trigger is NOT known. Falsified by measurement, each with 60 W holding:
    # an idle GPU for minutes, an opened+closed Vulkan context, an opened+closed
    # OpenCL context, display-manager starting and gnome-shell taking the device,
    # and a gamemode activation (which was the best suspect, since gaming.nix sets
    # apply_gpu_optimisations + nv_powermizer_mode=1 against card0, and card0 is
    # the NVIDIA GPU here). The untested difference is Steam's pressure-vessel
    # runtime, or sustained real game load.
    #
    # Likely relevant, and the best lead for why this hardware behaves this way at
    # all: the nvidia module initialises at 8.160 s and asus-nb-wmi only registers
    # platform_profile support at 8.251 s. The GPU driver comes up 91 ms before
    # the ASUS platform interface exists.
    #
    # Ordered before display-manager so GDM has not taken the device yet. The
    # lactd stop is defensive: LACT is disabled in constellation.gaming now, but
    # it held /dev/nvidia* and would block the rmmod if it ever comes back.
    # Every step is fail-soft: a failure here must never block boot.
    systemd.services.nvidia-unclamp-tgp = {
      description = "Reload NVIDIA modules to clear the boot-time 30 W dGPU clamp";
      wantedBy = ["display-manager.service"];
      before = ["display-manager.service"];
      after = ["systemd-udev-settle.service"];
      unitConfig.ConditionPathExists = "/dev/nvidia0";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set +e
        systemctl stop lactd 2>/dev/null
        for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
          ${pkgs.kmod}/bin/modprobe -r "$m" 2>/dev/null
        done
        ${pkgs.kmod}/bin/modprobe nvidia
        ${pkgs.kmod}/bin/modprobe nvidia_modeset 2>/dev/null
        ${pkgs.kmod}/bin/modprobe nvidia_drm 2>/dev/null
        systemctl start lactd 2>/dev/null
        exit 0
      '';
    };

    # Two panel readouts for that clamp, since a fix nobody can see is a fix
    # nobody can check. Astra Monitor's GPU menu carries the full picture --
    # Current / Default / Max Power Limit, P-state, memory clock, power draw --
    # and the Executor entry keeps the one number that matters in the top bar.
    # Both extensions come from constellation.desktop.gnome.gpuMonitor in configuration.nix.
    #
    # This is a second dconf database rather than an edit to the desktop module's:
    # databases layer in list order and only keys defined in both would conflict.
    # These keys are defined in neither, so nothing here is at risk of shadowing
    # the shared enabled-extensions list.
    #
    # The instrument is not neutral. Astra polls with `nvidia-smi -q -x -lms`,
    # which is a permanent NVML client this machine did not have before; if the
    # clamp's behaviour changes after this lands, suspect the monitor first.
    programs.dconf.profiles.user.databases = [
      {
        settings = {
          # Executor's commands live in one JSON string per panel position. The
          # left and center defaults are a demo `echo`, so they are turned off.
          "org/gnome/shell/extensions/executor" = {
            left-active = false;
            center-active = false;
            right-active = true;
            right-commands-json = builtins.toJSON {
              commands = [
                {
                  isActive = true;
                  command = lib.getExe dgpu-power;
                  interval = 10;
                  uuid = "a1b2c3d4-0d6e-4750-9077-65726361705f";
                }
              ];
            };
          };

          # gpu-data is the list Astra actually polls; gpu-main is the one the
          # panel header shows. Only the dGPU is listed -- adding the Renoir iGPU
          # would start an amdgpu_top poller for a GPU with nothing to watch.
          "org/gnome/shell/extensions/astra-monitor" = {
            gpu-header-show = true;
            gpu-main = builtins.toJSON dgpu;
            gpu-data = builtins.toJSON [(dgpu // {monitor = true;})];
            gpu-update = 5.0; # 2 s by default; this is a laptop and the clamp is not fast
          };
        };
      }
    ];

    # NVIDIA suspend/resume. Which mechanism runs follows `hardware.nvidia.open`:
    # kernelSuspendNotifier defaults to `open && version >= 595` and nixpkgs
    # asserts it off for the closed modules. In notifier mode nixpkgs installs no
    # nvidia-suspend/-resume units at all; with the closed CachyOS modules
    # (open = false, hardware-configuration.nix) it installs the legacy ones,
    # which run NVIDIA's nvidia-sleep.sh.
    #
    # That script records the foreground VT and parks the console on VT 63 for
    # suspend, then on resume unconditionally `chvt`s back to the recorded VT.
    # It races the session's own lock: on resume gala switches LightDM to the
    # greeter on VT 1, and the resume write to /proc/driver/nvidia/suspend takes
    # ~1.5s, so the restore lands *after* the greeter is up and yanks the console
    # back to the still-locked session. That session shows only gala's black lock
    # shield (the cursor, a hardware plane, still moves) and the greeter that
    # would unlock it sits on a VT nobody can see. Measured 2026-10-25: LightDM
    # activated VT 1 and logged the switch back to the session 0.35s later, the
    # moment nvidia-resume finished. When nvidia-resume happens to win, it works,
    # which is why it only failed sometimes.
    #
    # So restore the VT only if the console is still parked on 63, i.e. nothing
    # else has claimed it since. Guarded on the legacy units existing: in notifier
    # mode a bare ExecStart here would create a stray unit (and declaring
    # nvidia-suspend/-resume there once produced an empty, requiredBy-suspend unit
    # that aborted every suspend).
    systemd.services.nvidia-resume = lib.mkIf (config.hardware.nvidia.powerManagement.enable && !config.hardware.nvidia.powerManagement.kernelSuspendNotifier) {
      serviceConfig.ExecStart = lib.mkForce (pkgs.writeShellScript "nvidia-resume" ''
        [ -f /proc/driver/nvidia/suspend ] || exit 0
        echo resume > /proc/driver/nvidia/suspend
        vt_file=/run/nvidia-sleep/Xorg.vt_number
        [ -f "$vt_file" ] || exit 0
        vt=$(<"$vt_file")
        rm -f "$vt_file"
        if [ "$(fgconsole)" = 63 ]; then
          chvt "$vt"
        fi
      '');
    };
  };
}
