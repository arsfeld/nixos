let
  secret = {
    type = "string";
    sensitive = true;
  };
  plain.type = "string";
in {
  variable = {
    # Names must match what the OCI resource-discovery tool expects
    # (TF_VAR_tenancy_ocid, TF_VAR_user_ocid, TF_VAR_fingerprint,
    # TF_VAR_region, TF_VAR_private_key_path) so that `just tf` and discovery
    # authenticate from one identical environment.
    tenancy_ocid = plain;
    user_ocid = plain;
    fingerprint = plain;
    region = plain;

    # A PEM cannot survive a line-oriented dotenv round trip, so the key is
    # stored base64-encoded and materialised to a temp file by `just tf`.
    private_key_path = plain;

    cloudflare_api_token = secret;
  };
}
