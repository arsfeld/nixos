{
  lib,
  python3,
  uv,
  writeShellScriptBin,
}:
writeShellScriptBin "supabase-manager" ''
  exec ${uv}/bin/uv run --quiet --script ${./supabase-manager.py} "$@"
''
