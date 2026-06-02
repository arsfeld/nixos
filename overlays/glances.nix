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
      ];
  });
}
