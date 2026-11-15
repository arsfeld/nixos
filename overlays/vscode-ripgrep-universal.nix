# vscode 1.144.0 moved its bundled ripgrep from
#   resources/app/node_modules/@vscode/ripgrep/bin/rg
# to
#   resources/app/node_modules.asar.unpacked/@vscode/ripgrep-universal/bin/linux-x64/rg
# but nixpkgs' postPatch still removes and replaces the old path, so the build
# fails in patchPhase with:
#
#   rm: cannot remove 'resources/app/node_modules/@vscode/ripgrep/bin/rg':
#   No such file or directory
#
# Point the rm/ln pair at the new binary. The replacement is a no-op on Darwin
# (whose path differs) and once nixpkgs fixes the path itself. Only for
# >= 1.144.0: stable (26.05) went back to shipping 1.119.0 in nixpkgs f1e5c35,
# which still has the old path, and rewriting it there fails the same rm.
# Delete when nixpkgs' vscode package handles ripgrep-universal.
final: prev: {
  vscode =
    if prev.lib.versionAtLeast prev.vscode.version "1.144.0"
    then
      prev.vscode.overrideAttrs (old: {
        postPatch =
          prev.lib.replaceStrings
          ["resources/app/node_modules/@vscode/ripgrep/bin/rg"]
          ["resources/app/node_modules.asar.unpacked/@vscode/ripgrep-universal/bin/linux-x64/rg"]
          old.postPatch;
      })
    else prev.vscode;
}
