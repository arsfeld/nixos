# stash 0.31.1 vendors golang.org/x/tools 0.38.0, which cannot type-check a
# package that only imports "embed" under Go 1.27: `go generate ./cmd/stash`
# fails with `internal error: package "embed" without types was imported from
# "github.com/stashapp/stash/ui"`. Build it with the Go 1.26 it was written
# against until upstream's vendored x/tools catches up. Delete once
# nixpkgs-unstable's stash builds with its default Go (or the package bumps
# x/tools past the fix).
final: prev: {
  stash =
    if prev.lib.versionAtLeast prev.go.version "1.27"
    then
      prev.stash.override {
        buildGoModule = prev.buildGoModule.override {go = prev.go_1_26;};
      }
    else prev.stash;
}
