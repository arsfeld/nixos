final: prev: {
  glances = prev.glances.overridePythonAttrs (old:
    {
      # python-jose is marked insecure (CVE-2026-120459) since nixpkgs
      # f1e5c35 (2026-11-13). glances imports it in a try/except and uses it
      # only for JWT auth on its web server (glances/jwt_utils.py); we install
      # glances as a terminal tool from home/home.nix and no host runs its web
      # server. Drop it rather than permit an insecure package. Delete once
      # nixpkgs stops depending on it.
      dependencies = builtins.filter (p: (p.pname or "") != "python-jose") (old.dependencies or []);
      pythonRemoveDeps = (old.pythonRemoveDeps or []) ++ ["python-jose"];
    }
    # glances 4.5.5 (NixOS 26.05) on aarch64: phys_core() returns None in the
    # build sandbox, so tests/test_plugin_load.py::test_phys_core_returns_int
    # fails its int assertion. Measured 2026-11-10 on basestar: it is the only
    # failure (616 passed). Delete once nixpkgs' aarch64 glances builds.
    // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
      disabledTests = (old.disabledTests or []) ++ ["test_phys_core_returns_int"];
    });
}
