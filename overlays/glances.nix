# glances 4.5.5 (NixOS 26.05) on aarch64: phys_core() returns None in the
# build sandbox, so tests/test_plugin_load.py::test_phys_core_returns_int
# fails its int assertion. Measured 2026-11-10 on basestar: it is the only
# failure (616 passed). x86_64 builds pass unmodified, so leave them alone and
# keep their cache.nixos.org hits. Delete once nixpkgs' aarch64 glances builds.
final: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
  glances = prev.glances.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or []) ++ ["test_phys_core_returns_int"];
  });
}
