{
  imports = [
    ./terraform.nix
    ./variables.nix
    ./providers.nix
    ./oci/network.nix
    ./oci/basestar.nix
    ./dns/arsfeld-dev.nix
    ./dns/arsfeld-one.nix
    ./dns/rosenfeld-one.nix
  ];
}
