final: prev: {
  # Pin ananicy-cpp to 1.2.0. Upstream nixpkgs is still on 1.1.1.
  # https://gitlab.com/ananicy-cpp/ananicy-cpp/-/releases/v1.2.0
  ananicy-cpp = prev.ananicy-cpp.overrideAttrs (old: {
    version = "1.2.0";
    src = final.fetchFromGitLab {
      owner = "ananicy-cpp";
      repo = "ananicy-cpp";
      rev = "v1.2.0";
      hash = "sha256-XEeTf6+Ss7AiogGR/fyH168BjN/TvoYt2Gn7zLEWaRw=";
    };
    # Drop nixpkgs patches — they're upstreamed in 1.2.0
    patches = [];
  });
}
