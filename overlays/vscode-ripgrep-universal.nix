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
# (whose path differs) and once nixpkgs fixes the path itself. Delete when
# nixpkgs' vscode package handles ripgrep-universal.
final: prev: {
  vscode = prev.vscode.overrideAttrs (old: {
    postPatch =
      prev.lib.replaceStrings
      ["resources/app/node_modules/@vscode/ripgrep/bin/rg"]
      ["resources/app/node_modules.asar.unpacked/@vscode/ripgrep-universal/bin/linux-x64/rg"]
      old.postPatch;
  });
}
