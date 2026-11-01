# nixpkgs' replaceDirectDependencies, with two fixes the graft needed.
#
# 1. Same-name rewrites substitute the bare hash, not the basename; see the
#    comment in createRewriteScript.
#
# 2. The stock builder streams `nix-store --dump | sed | nix-store --restore`.
# --restore rejects a NAR whose directory entries are not sorted, and a
# rewrite reorders siblings when a store hash is part of an entry *name*: the
# FHS rootfs of bottles and lutris merge gstreamer's
# share/gdb/auto-load/nix/store/<hash>-gstreamer-* entries, and the graft
# rewrites those hashes. When --restore fails, unpack the same rewritten
# stream with nar-restore.py, which does not check ordering. Everything that
# restores cleanly takes the stock path unchanged.
#
# Loaded as an overlay by brotli-cve-2026-111497.nix; the `__` prefix keeps
# haumea from loading it as a module. Delete with that file.
{
  lib,
  runCommandLocal,
  nix,
  python3Minimal,
}: {
  drv,
  replacements ? [],
}: let
  inherit
    (lib)
    isStringLike
    substring
    stringLength
    optionalString
    escapeShellArgs
    concatMap
    ;

  isNonCaStorePath = x:
    if isStringLike x
    then let
      str = toString x;
    in
      builtins.substring 0 1 str == "/" && (dirOf str == builtins.storeDir)
    else false;
in
  if replacements == []
  then drv
  else let
    drvName =
      if isNonCaStorePath drv
      then
        # Reconstruct the name from the actual store path if available.
        substring 33 (stringLength (baseNameOf drv)) (baseNameOf drv)
      else if drv ? drvAttrs.name
      then
        # Try to get the name from the derivation arguments otherwise (for floating or deferred derivations).
        drv.drvAttrs.name
        + (
          let
            outputName = drv.outputName or "out";
          in
            optionalString (outputName != "out") "-${outputName}"
        )
      else throw "cannot reconstruct the derivation name from ${drv}";
  in
    runCommandLocal drvName {nativeBuildInputs = [nix.out python3Minimal];} ''
      createRewriteScript() {
          while [ $# -ne 0 ]; do
              oldBasename="$(basename "$1")"
              newBasename="$(basename "$2")"
              shift 2
              if [ ''${#oldBasename} -ne ''${#newBasename} ]; then
                  echo "cannot rewrite $oldBasename to $newBasename: length does not match" >&2
                  exit 1
              fi
              if [ "''${oldBasename:33}" = "''${newBasename:33}" ]; then
                  # Same name, so only the hash differs: rewrite the bare
                  # hash. A compiler can tail-merge string constants so the
                  # full basename never appears contiguously (sane-backends'
                  # etc/sane.d path did), and a basename match then leaves a
                  # stale reference behind. The hash is what Nix itself scans.
                  echo "s|''${oldBasename:0:32}|''${newBasename:0:32}|g" >> rewrite.sed
              else
                  echo "s|$oldBasename|$newBasename|g" >> rewrite.sed
              fi
          done
      }
      createRewriteScript ${
        escapeShellArgs (
          [
            drv
            (placeholder "out")
          ]
          ++ concatMap (
            {
              oldDependency,
              newDependency,
            }: [
              oldDependency
              newDependency
            ]
          )
          replacements
        )
      }
      if ! nix-store --dump ${drv} | sed -f rewrite.sed | nix-store --restore $out; then
          echo "nix-store --restore rejected the rewritten NAR; unpacking without the sort check" >&2
          if [ -e $out ]; then chmod -R u+w $out; rm -rf $out; fi
          nix-store --dump ${drv} | sed -f rewrite.sed | python3 ${./nar-restore.py} $out
      fi
    ''
