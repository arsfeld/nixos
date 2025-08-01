# Installing NixOS with Tailscale Connectivity

This document describes how to install NixOS on remote systems while maintaining Tailscale connectivity throughout the process.

## The Problem

When using `nixos-anywhere` to install NixOS on a remote system:
1. The tool uses kexec to boot into a minimal installer environment
2. This replaces the running system completely
3. If you're connected via Tailscale, you lose connection
4. The installation continues but you can't monitor or access it until completion

## The Solution: Custom Kexec with Tailscale

We've created a custom kexec image that includes Tailscale, allowing you to maintain connectivity throughout the installation process.

### Features

- **Tailscale Pre-installed**: The kexec installer includes Tailscale and can restore existing authentication
- **State Preservation**: Automatically preserves and restores Tailscale state from the target system
- **ZFS Support**: Includes ZFS tools for systems using ZFS
- **Full Network Stack**: Maintains network connectivity during installation

## Usage

### Method 1: Using Just Commands (Recommended)

```bash
# Build the custom kexec image
just build-kexec

# Install using the Tailscale-enabled kexec
just install cottage cottage.bat-boa.ts.net ./result
```

### Method 2: Manual nixos-anywhere

```bash
# Build the kexec image
nix build .#kexec-tailscale

# Run nixos-anywhere with the custom kexec
nixos-anywhere \
  --kexec ./result \
  --flake .#cottage \
  root@cottage.bat-boa.ts.net
```

## How It Works

1. **Preservation Phase**:
   - Extracts Tailscale state from `/var/lib/tailscale` on the target
   - Uploads it to the target's `/tmp` directory

2. **Kexec Phase**:
   - Target reboots into our custom kexec image
   - Kexec image includes Tailscale daemon
   - Automatically restores Tailscale state if available
   - You can connect via Tailscale to monitor installation

3. **Installation Phase**:
   - nixos-anywhere proceeds with disk formatting and installation
   - You maintain SSH access via Tailscale throughout
   - Can monitor logs and troubleshoot if needed

4. **Completion**:
   - System reboots into newly installed NixOS
   - Tailscale state is preserved in the final system
   - No need to re-authenticate Tailscale

## Alternative: Standard Installation without Custom Kexec

If you don't need to maintain Tailscale connectivity during installation:

```bash
# Standard installation (will lose Tailscale connection during kexec)
just install cottage 192.168.1.100
```

## Customizing the Kexec Image

The kexec image is defined in `kexec-tailscale.nix`. You can customize:

- Additional packages in the installer
- Network configuration
- Pre-authentication scripts
- Default credentials

## Troubleshooting

### Kexec Image Won't Build
```bash
# Clean and rebuild
rm -rf result
nix build .#kexec-tailscale --recreate-lock-file
```

### Can't Connect After Kexec
1. Wait 2-3 minutes for the kexec to complete
2. Try connecting via local IP if available
3. Check if Tailscale service started: `systemctl status tailscaled`

### Tailscale State Not Restored
- Ensure the target has Tailscale installed and authenticated before installation
- Check that `/var/lib/tailscale` exists on the target
- Verify the state file was uploaded to `/tmp/tailscale-state.tar.gz`

## Comparison with Other Methods

### vs Standard nixos-anywhere
- ✅ Maintains Tailscale connectivity
- ✅ Can monitor installation progress
- ❌ Requires building custom kexec image
- ❌ Slightly larger download

### vs nixos-infect
- ✅ More reliable and predictable
- ✅ Can reformat disks completely
- ✅ Works with disko configurations
- ❌ Still has brief downtime during kexec

### vs Manual Installation
- ✅ Fully automated
- ✅ Reproducible
- ✅ No manual partitioning needed
- ❌ Requires working Nix on local machine