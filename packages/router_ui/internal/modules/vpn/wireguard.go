package vpn

import (
	"fmt"
	"net"
	"strings"
)

// WireGuardConfig represents a WireGuard configuration
type WireGuardConfig struct {
	Interface WireGuardInterface
	Peers     []WireGuardPeer
}

// WireGuardInterface represents the [Interface] section
type WireGuardInterface struct {
	PrivateKey string
	Address    []string // IPv4/IPv6 addresses with CIDR
	DNS        []string
	MTU        int
	Table      string // Routing table (e.g., "off", "auto", or table number)
	PreUp      []string
	PostUp     []string
	PreDown    []string
	PostDown   []string
}

// WireGuardPeer represents a [Peer] section
type WireGuardPeer struct {
	PublicKey           string
	PresharedKey        string
	Endpoint            string
	AllowedIPs          []string
	PersistentKeepalive int
}

// GenerateWireGuardConfig generates a WireGuard configuration file content
func GenerateWireGuardConfig(provider *Provider, clientIP string) (string, error) {
	if provider.Type != "wireguard" {
		return "", fmt.Errorf("provider type must be wireguard, got %s", provider.Type)
	}

	// Validate required fields
	if provider.PrivateKey == "" {
		return "", fmt.Errorf("private key is required")
	}
	if provider.PublicKey == "" {
		return "", fmt.Errorf("public key is required")
	}
	if provider.Endpoint == "" {
		return "", fmt.Errorf("endpoint is required")
	}

	var sb strings.Builder

	// [Interface] section
	sb.WriteString("[Interface]\n")
	sb.WriteString(fmt.Sprintf("PrivateKey = %s\n", provider.PrivateKey))
	
	// Address from config
	if addresses, ok := provider.Config["addresses"]; ok {
		sb.WriteString(fmt.Sprintf("Address = %s\n", addresses))
	}
	
	// DNS servers
	if dns, ok := provider.Config["dns"]; ok {
		sb.WriteString(fmt.Sprintf("DNS = %s\n", dns))
	}
	
	// MTU
	if mtu, ok := provider.Config["mtu"]; ok {
		sb.WriteString(fmt.Sprintf("MTU = %s\n", mtu))
	}
	
	// Disable routing table (we'll handle routing ourselves)
	sb.WriteString("Table = off\n")
	
	// PostUp commands for routing
	if clientIP != "" {
		// Mark packets from specific client
		sb.WriteString(fmt.Sprintf("PostUp = iptables -t mangle -A PREROUTING -s %s -j MARK --set-mark 0x%s\n", 
			clientIP, provider.Config["fwmark"]))
		// Add routing rule
		sb.WriteString(fmt.Sprintf("PostUp = ip rule add from %s table %s\n", 
			clientIP, provider.Config["table"]))
		// Add default route in custom table
		sb.WriteString(fmt.Sprintf("PostUp = ip route add default dev %%i table %s\n", 
			provider.Config["table"]))
		
		// PostDown commands to clean up
		sb.WriteString(fmt.Sprintf("PostDown = iptables -t mangle -D PREROUTING -s %s -j MARK --set-mark 0x%s\n", 
			clientIP, provider.Config["fwmark"]))
		sb.WriteString(fmt.Sprintf("PostDown = ip rule del from %s table %s\n", 
			clientIP, provider.Config["table"]))
		sb.WriteString(fmt.Sprintf("PostDown = ip route del default dev %%i table %s\n", 
			provider.Config["table"]))
	}
	
	sb.WriteString("\n")
	
	// [Peer] section
	sb.WriteString("[Peer]\n")
	sb.WriteString(fmt.Sprintf("PublicKey = %s\n", provider.PublicKey))
	
	if provider.PresharedKey != "" {
		sb.WriteString(fmt.Sprintf("PresharedKey = %s\n", provider.PresharedKey))
	}
	
	sb.WriteString(fmt.Sprintf("Endpoint = %s\n", provider.Endpoint))
	
	// AllowedIPs
	allowedIPs := "0.0.0.0/0, ::/0" // Default to all traffic
	if ips, ok := provider.Config["allowed_ips"]; ok {
		allowedIPs = ips
	}
	sb.WriteString(fmt.Sprintf("AllowedIPs = %s\n", allowedIPs))
	
	// PersistentKeepalive
	if keepalive, ok := provider.Config["keepalive"]; ok {
		sb.WriteString(fmt.Sprintf("PersistentKeepalive = %s\n", keepalive))
	} else {
		sb.WriteString("PersistentKeepalive = 25\n")
	}
	
	return sb.String(), nil
}

// GenerateInterfaceName generates a unique interface name for a VPN provider
func GenerateInterfaceName(providerName string) string {
	// Sanitize the provider name
	name := strings.ToLower(providerName)
	name = strings.ReplaceAll(name, " ", "-")
	name = strings.ReplaceAll(name, "_", "-")
	
	// Ensure it starts with "wg-"
	if !strings.HasPrefix(name, "wg-") {
		name = "wg-" + name
	}
	
	// Limit length to 15 characters (Linux interface name limit)
	if len(name) > 15 {
		name = name[:15]
	}
	
	return name
}

// ValidateEndpoint validates a WireGuard endpoint
func ValidateEndpoint(endpoint string) error {
	// Endpoint should be in format host:port
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return fmt.Errorf("invalid endpoint format: %w", err)
	}
	
	// Validate port
	if _, err := net.LookupPort("udp", port); err != nil {
		return fmt.Errorf("invalid port: %w", err)
	}
	
	// Validate host (can be IP or hostname)
	if net.ParseIP(host) == nil {
		// Not an IP, try to resolve as hostname
		if _, err := net.LookupHost(host); err != nil {
			return fmt.Errorf("cannot resolve host: %w", err)
		}
	}
	
	return nil
}