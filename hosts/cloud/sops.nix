{
  config,
  self,
  ...
}: {
  # Configure sops-nix for cloud host
  sops = {
    defaultSopsFile = "${self}/secrets/sops/cloud-poc.yaml";
    age = {
      # Use the host's SSH key for decryption
      sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
      # Generate age key from SSH key on first boot
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };

    # Define secrets from cloud-poc.yaml
    secrets = {
      ntfy-env = {
        mode = "0444";
      };
      siyuan-auth-code = {
        owner = "root";
        group = "root";
      };
    };
  };
}
