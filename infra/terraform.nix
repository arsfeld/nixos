{
  # No `version` constraints: nixpkgs pins the provider binaries, and a second
  # constraint here would drift against it on every nixpkgs bump.
  terraform.required_providers = {
    oci.source = "oracle/oci";
    cloudflare.source = "cloudflare/cloudflare";
  };
}
