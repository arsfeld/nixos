# cylon-link-boot, built from here twice: for the Steam Link (install hook and
# boot confirmation) and for the build platform (`just flash-cylon-link`, the
# flake check). run.sh travels as data: it runs under Valve's firmware.
{
  writeShellApplication,
  coreutils,
  # Static armv7l kexec, as a string with store context.
  kexec,
  # kexec_load.ko for Valve's 3.8.13 kernel, as a string with store context.
  kexecModule,
  dtbName ? "berlin2cd-valve-steamlink.dtb",
}:
writeShellApplication {
  name = "cylon-link-boot";
  runtimeInputs = [coreutils];
  # Interpolated, not bare paths: toShellVar would render a path without
  # copying it into the store, and the device would never receive run.sh.
  runtimeEnv = {
    RUN_SH = "${./run.sh}";
    KEXEC = kexec;
    KEXEC_MODULE = kexecModule;
    DTB_NAME = dtbName;
  };
  text = builtins.readFile ./cylon-link-boot.sh;
}
