# cylon-link: Valve Steam Link, cross-compiled on raider. Configuration in ./cylon-link/.
{
  configurations.nixos.cylon-link = {
    homeManager = false;
    # CI never builds this host. It is cross-compiled for armv7l and its kernel
    # alone outlasts the build job's 120-minute timeout on a GitHub runner.
    # raider builds it in `just deploy` phase 1 instead.
    ci = false;
    module = {};
  };
}
