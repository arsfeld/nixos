# Codeman: a web dashboard that runs agent CLIs (claude, agy, ...) in tmux
# sessions. Served on raider by modules/hosts/raider/codeman.nix.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_22,
  python3,
  makeWrapper,
  tmux,
}:
buildNpmPackage rec {
  pname = "codeman";
  version = "1.51.1";

  src = fetchFromGitHub {
    owner = "Ark0N";
    repo = "Codeman";
    tag = "codeman@${version}";
    hash = "sha256-hJNMa+RFrHEJbl0QaLWCgyF7r1/cwVQ/3pXgYjvFV/Y=";
  };

  npmDepsHash = "sha256-y7OTCy3fy7Hv3OMSvi6qsgKnSNNSLKAqOffEVe33eyU=";
  nodejs = nodejs_22;

  # puppeteer (a devDependency, for its tests) downloads Chrome on install.
  env.PUPPETEER_SKIP_DOWNLOAD = "1";

  # node-gyp builds node-pty's native addon.
  nativeBuildInputs = [python3 makeWrapper];

  # The repo's .npmrc is `include=dev`, which overrides the install hook's
  # `npm prune --omit=dev` and ships every devDependency (remotion,
  # puppeteer, playwright, ...). The build still gets them: npm ci installs
  # dev dependencies by default.
  #
  # The tmux server, and so every agent pane, inherits the environment of the
  # session that starts it. Upstream drops only TMUX, which left the web
  # login (CODEMAN_PASSWORD) in every agent's environment, and from there in
  # transcripts and scrollback. The server reads it from its own process
  # environment, never the panes'. The cost: `codeman agent` run inside a
  # session no longer finds the password and gets 401.
  postPatch = ''
    rm .npmrc
    substituteInPlace src/tmux-manager.ts --replace-fail \
      'delete cleanEnv.TMUX;' \
      'delete cleanEnv.TMUX; delete cleanEnv.CODEMAN_PASSWORD; delete cleanEnv.CODEMAN_USERNAME;'
  '';

  # npm links each workspace into node_modules, but package.json's `files`
  # leaves packages/ out of the install, so those links dangle.
  postInstall = ''
    find $out/lib/node_modules/aicodeman/node_modules -maxdepth 1 -xtype l -delete
  '';

  postFixup = ''
    wrapProgram $out/bin/codeman --prefix PATH : ${lib.makeBinPath [tmux]}
  '';

  meta = {
    description = "Web dashboard for Claude Code and other agent CLIs, running in tmux";
    homepage = "https://github.com/Ark0N/Codeman";
    license = lib.licenses.mit;
    mainProgram = "codeman";
    platforms = lib.platforms.linux;
  };
}
