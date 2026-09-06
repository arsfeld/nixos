{
  terraform = {
    # No `version` constraints: nixpkgs pins the provider binaries, and a second
    # constraint here would drift against it on every nixpkgs bump.
    required_providers = {
      oci.source = "oracle/oci";
      cloudflare.source = "cloudflare/cloudflare";
    };

    # State lives in R2, reached through the S3-compatible API. Credentials come
    # from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the environment: backend
    # configuration cannot reference variables.
    #
    # The account ID is already committed in hosts/basestar/services/niks3.nix,
    # so naming it here adds no exposure. Every skip_* below turns off an
    # AWS-specific validation or metadata call that R2 does not implement;
    # use_lockfile gets state locking from R2's conditional PUT support, which
    # is why no DynamoDB substitute is needed.
    #
    # Never add an R2 lifecycle rule to this bucket. Object versioning is the
    # only undo available for a corrupted state file.
    backend.s3 = {
      bucket = "tfstate";
      key = "nixos-infra.tfstate";
      region = "auto";
      endpoints.s3 = "https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com";
      use_path_style = true;
      use_lockfile = true;
      skip_credentials_validation = true;
      skip_region_validation = true;
      skip_requesting_account_id = true;
      skip_metadata_api_check = true;
      skip_s3_checksum = true;
    };
  };
}
