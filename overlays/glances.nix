# glances 4.5.4 (NixOS 26.05) adds tests/test_plugin_load.py::test_phys_core_returns_int,
# which calls phys_core() and asserts the result is an int. In the Nix build sandbox
# (notably on aarch64), physical-core detection returns None, so the assertion fails.
# This is environment-sensitive, not a real defect, so disable just that test.
final: prev: {
  glances = prev.glances.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or []) ++ ["test_phys_core_returns_int"];
  });
}
