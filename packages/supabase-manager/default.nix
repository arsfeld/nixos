{pkgs}:
pkgs.writeShellScriptBin "supabase-manager" ''
  exec ${pkgs.uv}/bin/uv run --quiet --script ${./supabase-manager.py} "$@"
''
