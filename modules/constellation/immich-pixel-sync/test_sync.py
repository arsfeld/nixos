"""Unit tests for the Immich → Pixel stager.

Deliberately hermetic: no database, no exiftool, no Immich library. Everything
tested here is a pure function or a tmpdir operation, so the whole file runs
inside a Nix build.
"""

import unittest

import sync


class ConfigTest(unittest.TestCase):
    def test_module_imports_without_any_environment(self):
        self.assertTrue(callable(sync.main))


if __name__ == "__main__":
    unittest.main()
