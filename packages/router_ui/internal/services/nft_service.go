package services

import (
	"fmt"
	"os/exec"
	"strings"
	"sync"

	"github.com/arosenfeld/nixos/packages/router_ui/internal/modules/vpn"
)

// NFTService manages nftables rules for VPN routing
type NFTService struct {
	mu sync.Mutex
}

// NewNFTService creates a new NFT service
func NewNFTService() *NFTService {
	return &NFTService{}
}

// Initialize creates the VPN routing table structure
func (s *NFTService) Initialize() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	// Create the VPN routing table
	rules := `
table ip vpn_routing {
	chain prerouting {
		type filter hook prerouting priority mangle;
	}
	
	chain postrouting {
		type nat hook postrouting priority srcnat;
	}
	
	chain forward {
		type filter hook forward priority filter;
		ct state established,related accept
	}
}
`
	
	// Apply the base table structure
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(rules)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to create NFT table: %w, output: %s", err, output)
	}
	
	return nil
}

// AddClientVPNRule adds routing rules for a specific client-to-VPN mapping
func (s *NFTService) AddClientVPNRule(clientIP string, provider *vpn.Provider, mark int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	// Add prerouting rule to mark packets
	preroutingRule := fmt.Sprintf(
		"add rule ip vpn_routing prerouting ip saddr %s meta mark set 0x%x",
		clientIP, mark)
	
	if err := s.executeNFT(preroutingRule); err != nil {
		return fmt.Errorf("failed to add prerouting rule: %w", err)
	}
	
	// Add postrouting NAT rule
	postroutingRule := fmt.Sprintf(
		"add rule ip vpn_routing postrouting meta mark 0x%x oifname \"%s\" masquerade",
		mark, provider.InterfaceName)
	
	if err := s.executeNFT(postroutingRule); err != nil {
		return fmt.Errorf("failed to add postrouting rule: %w", err)
	}
	
	// Add kill-switch rule if enabled
	forwardRule := fmt.Sprintf(
		"add rule ip vpn_routing forward meta mark 0x%x oifname != \"%s\" drop",
		mark, provider.InterfaceName)
	
	if err := s.executeNFT(forwardRule); err != nil {
		return fmt.Errorf("failed to add forward rule: %w", err)
	}
	
	return nil
}

// RemoveClientVPNRule removes routing rules for a specific client
func (s *NFTService) RemoveClientVPNRule(clientIP string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	// List rules in prerouting chain and find the one for this client
	cmd := exec.Command("nft", "-a", "list", "chain", "ip", "vpn_routing", "prerouting")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to list rules: %w", err)
	}
	
	// Parse output to find rule handles
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		if strings.Contains(line, fmt.Sprintf("ip saddr %s", clientIP)) {
			// Extract handle number
			parts := strings.Fields(line)
			for i, part := range parts {
				if part == "handle" && i+1 < len(parts) {
					handle := parts[i+1]
					// Delete the rule
					deleteCmd := fmt.Sprintf("delete rule ip vpn_routing prerouting handle %s", handle)
					if err := s.executeNFT(deleteCmd); err != nil {
						return fmt.Errorf("failed to delete prerouting rule: %w", err)
					}
					break
				}
			}
		}
	}
	
	// Similar process for postrouting and forward chains
	// TODO: Implement cleanup for other chains
	
	return nil
}

// FlushVPNRules removes all VPN routing rules
func (s *NFTService) FlushVPNRules() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	chains := []string{"prerouting", "postrouting", "forward"}
	for _, chain := range chains {
		cmd := fmt.Sprintf("flush chain ip vpn_routing %s", chain)
		if err := s.executeNFT(cmd); err != nil {
			return fmt.Errorf("failed to flush %s chain: %w", chain, err)
		}
	}
	
	return nil
}

// AddRoutingTable adds IP rules for policy-based routing
func (s *NFTService) AddRoutingTable(mark int, tableName string, interfaceName string) error {
	// Add routing rule for marked packets
	cmd := exec.Command("ip", "rule", "add", "fwmark", fmt.Sprintf("0x%x", mark), "table", tableName)
	if output, err := cmd.CombinedOutput(); err != nil {
		// Check if rule already exists
		if !strings.Contains(string(output), "File exists") {
			return fmt.Errorf("failed to add ip rule: %w, output: %s", err, output)
		}
	}
	
	// Add default route through VPN interface
	cmd = exec.Command("ip", "route", "add", "default", "dev", interfaceName, "table", tableName)
	if output, err := cmd.CombinedOutput(); err != nil {
		// Check if route already exists
		if !strings.Contains(string(output), "File exists") {
			return fmt.Errorf("failed to add route: %w, output: %s", err, output)
		}
	}
	
	return nil
}

// RemoveRoutingTable removes IP rules for a routing table
func (s *NFTService) RemoveRoutingTable(mark int, tableName string) error {
	// Remove routing rule
	cmd := exec.Command("ip", "rule", "del", "fwmark", fmt.Sprintf("0x%x", mark), "table", tableName)
	if err := cmd.Run(); err != nil {
		// Ignore if rule doesn't exist
		return nil
	}
	
	// Flush routing table
	cmd = exec.Command("ip", "route", "flush", "table", tableName)
	if err := cmd.Run(); err != nil {
		// Ignore if table is already empty
		return nil
	}
	
	return nil
}

// executeNFT executes an nft command
func (s *NFTService) executeNFT(command string) error {
	cmd := exec.Command("nft", strings.Fields(command)...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("nft command failed: %w, output: %s", err, output)
	}
	return nil
}