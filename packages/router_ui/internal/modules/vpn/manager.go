package vpn

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Manager handles VPN interface lifecycle
type Manager struct {
	configDir string
	encryptor interface {
		Decrypt(string) ([]byte, error)
	}
}

// NewManager creates a new VPN manager
func NewManager(configDir string, encryptor interface{ Decrypt(string) ([]byte, error) }) *Manager {
	return &Manager{
		configDir: configDir,
		encryptor: encryptor,
	}
}

// ApplyWireGuardConfig creates or updates a WireGuard interface
func (m *Manager) ApplyWireGuardConfig(provider *Provider, clientIP string) error {
	// Decrypt credentials if needed
	privateKey := provider.PrivateKey
	if m.encryptor != nil && strings.HasPrefix(privateKey, "AGE-SECRET-KEY") == false {
		decrypted, err := m.encryptor.Decrypt(privateKey)
		if err != nil {
			return fmt.Errorf("failed to decrypt private key: %w", err)
		}
		privateKey = string(decrypted)
	}

	presharedKey := provider.PresharedKey
	if m.encryptor != nil && presharedKey != "" && strings.HasPrefix(presharedKey, "AGE-SECRET-KEY") == false {
		decrypted, err := m.encryptor.Decrypt(presharedKey)
		if err != nil {
			return fmt.Errorf("failed to decrypt preshared key: %w", err)
		}
		presharedKey = string(decrypted)
	}

	// Create a temporary provider with decrypted keys
	decryptedProvider := *provider
	decryptedProvider.PrivateKey = privateKey
	decryptedProvider.PresharedKey = presharedKey

	// Generate config
	config, err := GenerateWireGuardConfig(&decryptedProvider, clientIP)
	if err != nil {
		return fmt.Errorf("failed to generate config: %w", err)
	}

	// Write config to file
	configPath := filepath.Join(m.configDir, provider.InterfaceName+".conf")
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		return fmt.Errorf("failed to write config: %w", err)
	}

	// Check if interface already exists
	if m.interfaceExists(provider.InterfaceName) {
		// Sync existing interface
		cmd := exec.Command("wg", "syncconf", provider.InterfaceName, configPath)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to sync wireguard config: %w, output: %s", err, output)
		}
	} else {
		// Create new interface
		cmd := exec.Command("wg-quick", "up", configPath)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to bring up wireguard interface: %w, output: %s", err, output)
		}
	}

	return nil
}

// StopInterface stops a VPN interface
func (m *Manager) StopInterface(interfaceName string) error {
	if !m.interfaceExists(interfaceName) {
		return nil // Already stopped
	}

	configPath := filepath.Join(m.configDir, interfaceName+".conf")
	cmd := exec.Command("wg-quick", "down", configPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to bring down wireguard interface: %w, output: %s", err, output)
	}

	return nil
}

// GetInterfaceStatus gets the status of a VPN interface
func (m *Manager) GetInterfaceStatus(interfaceName string) (*InterfaceStatus, error) {
	if !m.interfaceExists(interfaceName) {
		return &InterfaceStatus{
			Name:      interfaceName,
			Connected: false,
		}, nil
	}

	// Get WireGuard status
	cmd := exec.Command("wg", "show", interfaceName, "dump")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to get wireguard status: %w", err)
	}

	status := &InterfaceStatus{
		Name:      interfaceName,
		Connected: false, // Will be set to true if we find an active peer
	}

	// Parse output
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) > 1 && lines[1] != "" {
		// Parse peer information
		// Format: peer public_key preshared_key endpoint allowed_ips latest_handshake rx_bytes tx_bytes keepalive
		fields := strings.Fields(lines[1])
		if len(fields) >= 8 {
			// Parse latest handshake (unix timestamp)
			var handshake int64
			fmt.Sscanf(fields[5], "%d", &handshake)
			status.LastHandshake = handshake
			
			// Check if handshake is recent (within last 3 minutes)
			if handshake > 0 {
				timeSinceHandshake := time.Now().Unix() - handshake
				if timeSinceHandshake < 180 {
					status.Connected = true
					status.ConnectedSince = handshake
				}
			}
			
			// Parse traffic statistics
			fmt.Sscanf(fields[6], "%d", &status.BytesReceived)
			fmt.Sscanf(fields[7], "%d", &status.BytesSent)
		}
	}

	return status, nil
}

// interfaceExists checks if a network interface exists
func (m *Manager) interfaceExists(name string) bool {
	_, err := os.Stat(fmt.Sprintf("/sys/class/net/%s", name))
	return err == nil
}

// InterfaceStatus represents the status of a VPN interface
type InterfaceStatus struct {
	Name           string
	Connected      bool
	LastHandshake  int64
	BytesSent      int64
	BytesReceived  int64
	ConnectedSince int64
}