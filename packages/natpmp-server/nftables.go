package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func (nft *NFTablesManager) AddMapping(m *Mapping) error {
	cmd := fmt.Sprintf("add rule ip %s %s %s dport %d dnat to %s:%d",
		nft.config.NatTable,
		nft.config.NatChain,
		m.Protocol,
		m.ExternalPort,
		m.InternalIP,
		m.InternalPort,
	)
	
	log.Printf("Adding nftables rule: %s", cmd)
	
	_, err := nft.runNft(cmd)
	if err != nil {
		nftablesOperations.WithLabelValues("add", "error").Inc()
		return fmt.Errorf("failed to add nftables rule: %w", err)
	}
	nftablesOperations.WithLabelValues("add", "success").Inc()
	log.Printf("Successfully added nftables rule")
	
	// Find the handle of the newly added rule
	handle, err := nft.findRuleHandle(*m)
	if err != nil {
		log.Printf("Warning: could not find rule handle after adding: %v", err)
	} else {
		m.RuleHandle = handle
	}
	
	return nil
}

func (nft *NFTablesManager) RemoveMapping(m Mapping) error {
	if m.RuleHandle == 0 {
		log.Printf("Warning: no rule handle for mapping %s:%d -> %s:%d, trying to find it",
			m.InternalIP, m.InternalPort, m.InternalIP, m.ExternalPort)
		
		handle, err := nft.findRuleHandle(m)
		if err != nil {
			return fmt.Errorf("failed to find rule handle: %w", err)
		}
		m.RuleHandle = handle
	}
	
	cmd := fmt.Sprintf("delete rule ip %s %s handle %d",
		nft.config.NatTable,
		nft.config.NatChain,
		m.RuleHandle,
	)
	
	_, err := nft.runNft(cmd)
	if err != nil {
		nftablesOperations.WithLabelValues("delete", "error").Inc()
		return fmt.Errorf("failed to delete nftables rule: %w", err)
	}
	
	nftablesOperations.WithLabelValues("delete", "success").Inc()
	return nil
}

func (nft *NFTablesManager) EnsureTablesAndChains() error {
	commands := []string{
		fmt.Sprintf("add table ip %s", nft.config.NatTable),
		fmt.Sprintf("add chain ip %s %s { type nat hook prerouting priority dstnat; policy accept; }",
			nft.config.NatTable, nft.config.NatChain),
		fmt.Sprintf("add table ip %s", nft.config.FilterTable),
		fmt.Sprintf("add chain ip %s %s { type filter hook forward priority filter; policy accept; }",
			nft.config.FilterTable, nft.config.FilterChain),
	}
	
	for _, cmd := range commands {
		if _, err := nft.runNft(cmd); err != nil {
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("failed to ensure tables/chains: %w", err)
			}
		}
	}
	
	return nil
}

func (nft *NFTablesManager) CleanupAllMappings() error {
	cmd := fmt.Sprintf("-a list chain ip %s %s", nft.config.NatTable, nft.config.NatChain)
	output, err := nft.runNft(cmd)
	if err != nil {
		return err
	}
	
	re := regexp.MustCompile(`handle (\d+)`)
	matches := re.FindAllStringSubmatch(output, -1)
	
	for _, match := range matches {
		if len(match) > 1 {
			handle := match[1]
			delCmd := fmt.Sprintf("delete rule ip %s %s handle %s",
				nft.config.NatTable, nft.config.NatChain, handle)
			nft.runNft(delCmd)
		}
	}
	
	return nil
}

func (nft *NFTablesManager) runNft(args string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	cmd := exec.CommandContext(ctx, "nft", strings.Fields(args)...)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("nft command timed out after 5 seconds: %s", args)
	}
	if err != nil {
		return "", fmt.Errorf("nft command failed: %s: %s", err, output)
	}
	return string(output), nil
}

func (nft *NFTablesManager) extractHandle(output string) (uint64, error) {
	re := regexp.MustCompile(`# handle (\d+)`)
	matches := re.FindStringSubmatch(output)
	if len(matches) < 2 {
		return 0, fmt.Errorf("handle not found in output")
	}
	
	handle, err := strconv.ParseUint(matches[1], 10, 64)
	if err != nil {
		return 0, err
	}
	
	return handle, nil
}

func (nft *NFTablesManager) findRuleHandle(m Mapping) (uint64, error) {
	cmd := fmt.Sprintf("-a list chain ip %s %s", nft.config.NatTable, nft.config.NatChain)
	output, err := nft.runNft(cmd)
	if err != nil {
		return 0, err
	}
	
	pattern := fmt.Sprintf("%s dport %d dnat to %s:%d",
		m.Protocol, m.ExternalPort, m.InternalIP, m.InternalPort)
	
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		if strings.Contains(line, pattern) {
			re := regexp.MustCompile(`handle (\d+)`)
			matches := re.FindStringSubmatch(line)
			if len(matches) > 1 {
				return strconv.ParseUint(matches[1], 10, 64)
			}
		}
	}
	
	return 0, fmt.Errorf("rule not found")
}