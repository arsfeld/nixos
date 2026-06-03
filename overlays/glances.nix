# glances 4.5.4 (NixOS 26.05) has several sandbox-sensitive test failures, none a
# real defect:
#   - tests/test_plugin_load.py::test_phys_core_returns_int: phys_core() returns
#     None in the build sandbox (notably aarch64), so the int assertion fails.
#   - tests/test_api.py: errors at collection time with
#     `OSError: [Errno 25] Inappropriate ioctl for device (ioctl(SIOCETHTOOL))`
#     because the sandbox has no real network device to query. A collection-time
#     error can't be skipped via -k, so drop the whole module.
#   - tests/test_restful.py, tests/test_xmlrpc.py, tests/test_browser_restful.py:
#     spin up a local server and connect back over localhost; the build sandbox
#     has no loopback networking so the requests fail with `Connection refused`.
#   - tests/test_core.py and tests/test_memoryleak.py (aarch64 only): both run the
#     full stats update, which queries the network device via ioctl(SIOCETHTOOL).
#     Under aarch64 QEMU there's no real device, so it raises
#     `OSError: [Errno 25] Inappropriate ioctl for device`. The whole modules are
#     dropped on aarch64 (test_000_update populates state the rest of test_core.py
#     depends on, so disabling individual tests would cascade). On x86_64 they pass
#     and MUST stay enabled. Not a real defect.
final: prev: {
  glances = prev.glances.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or []) ++ ["test_phys_core_returns_int"];
    disabledTestPaths =
      (old.disabledTestPaths or [])
      ++ [
        "tests/test_api.py"
        "tests/test_restful.py"
        "tests/test_xmlrpc.py"
        "tests/test_browser_restful.py"
      ]
      ++ prev.lib.optionals prev.stdenv.hostPlatform.isAarch64 [
        "tests/test_core.py"
        "tests/test_memoryleak.py"
      ];
  });
}
