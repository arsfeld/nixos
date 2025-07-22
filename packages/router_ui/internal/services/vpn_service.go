package services

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/arosenfeld/nixos/packages/router_ui/internal/crypto"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/modules/vpn"
)

// VPNService manages VPN lifecycle and monitoring
type VPNService struct {
	db        *db.DB
	manager   *vpn.Manager
	encryptor *crypto.AgeEncryptor
	
	// Background goroutine management
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
	
	// State tracking
	mu        sync.RWMutex
	providers map[string]*vpn.Provider
	status    map[string]*vpn.InterfaceStatus
}

// NewVPNService creates a new VPN service
func NewVPNService(database *db.DB, configDir string, encryptor *crypto.AgeEncryptor) *VPNService {
	ctx, cancel := context.WithCancel(context.Background())
	
	// Ensure config directory exists
	if err := os.MkdirAll(configDir, 0700); err != nil {
		log.Printf("Warning: Failed to create WireGuard config directory: %v", err)
	}
	
	return &VPNService{
		db:        database,
		manager:   vpn.NewManager(configDir, encryptor),
		encryptor: encryptor,
		ctx:       ctx,
		cancel:    cancel,
		providers: make(map[string]*vpn.Provider),
		status:    make(map[string]*vpn.InterfaceStatus),
	}
}

// Start begins the VPN service and monitoring
func (s *VPNService) Start() error {
	log.Println("Starting VPN service...")
	
	// Load existing providers
	if err := s.loadProviders(); err != nil {
		return fmt.Errorf("failed to load providers: %w", err)
	}
	
	// Start enabled VPN interfaces
	for _, provider := range s.providers {
		if provider.Enabled {
			if err := s.startVPN(provider); err != nil {
				log.Printf("Failed to start VPN %s: %v", provider.Name, err)
			}
		}
	}
	
	// Start monitoring goroutines
	s.wg.Add(2)
	go s.monitorProviders()
	go s.monitorInterfaces()
	
	return nil
}

// Stop gracefully shuts down the VPN service
func (s *VPNService) Stop() error {
	log.Println("Stopping VPN service...")
	
	// Cancel context to stop goroutines
	s.cancel()
	
	// Wait for goroutines to finish
	s.wg.Wait()
	
	// Stop all VPN interfaces
	s.mu.RLock()
	providers := make([]*vpn.Provider, 0, len(s.providers))
	for _, p := range s.providers {
		providers = append(providers, p)
	}
	s.mu.RUnlock()
	
	for _, provider := range providers {
		if err := s.stopVPN(provider); err != nil {
			log.Printf("Failed to stop VPN %s: %v", provider.Name, err)
		}
	}
	
	return nil
}

// ApplyProvider applies a VPN provider configuration
func (s *VPNService) ApplyProvider(provider *vpn.Provider) error {
	s.mu.Lock()
	s.providers[provider.ID] = provider
	s.mu.Unlock()
	
	if provider.Enabled {
		return s.startVPN(provider)
	} else {
		return s.stopVPN(provider)
	}
}

// RemoveProvider removes a VPN provider
func (s *VPNService) RemoveProvider(providerID string) error {
	s.mu.Lock()
	provider, exists := s.providers[providerID]
	if exists {
		delete(s.providers, providerID)
	}
	s.mu.Unlock()
	
	if !exists {
		return nil
	}
	
	return s.stopVPN(provider)
}

// GetStatus returns the current status of all VPN interfaces
func (s *VPNService) GetStatus() map[string]*vpn.InterfaceStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	result := make(map[string]*vpn.InterfaceStatus, len(s.status))
	for k, v := range s.status {
		result[k] = v
	}
	return result
}

// Private methods

func (s *VPNService) loadProviders() error {
	keys, err := s.db.List("vpn:provider:")
	if err != nil {
		return err
	}
	
	s.mu.Lock()
	defer s.mu.Unlock()
	
	for _, key := range keys {
		var provider vpn.Provider
		if err := s.db.GetJSON(key, &provider); err != nil {
			log.Printf("Failed to load provider from %s: %v", key, err)
			continue
		}
		s.providers[provider.ID] = &provider
	}
	
	log.Printf("Loaded %d VPN providers", len(s.providers))
	return nil
}

func (s *VPNService) startVPN(provider *vpn.Provider) error {
	log.Printf("Starting VPN: %s", provider.Name)
	
	// For now, start without client-specific routing
	// TODO: Implement client-to-VPN mapping
	if err := s.manager.ApplyWireGuardConfig(provider, ""); err != nil {
		return fmt.Errorf("failed to apply wireguard config: %w", err)
	}
	
	// Update status
	status, err := s.manager.GetInterfaceStatus(provider.InterfaceName)
	if err != nil {
		return fmt.Errorf("failed to get interface status: %w", err)
	}
	
	s.mu.Lock()
	s.status[provider.ID] = status
	s.mu.Unlock()
	
	log.Printf("VPN %s started successfully on interface %s", provider.Name, provider.InterfaceName)
	return nil
}

func (s *VPNService) stopVPN(provider *vpn.Provider) error {
	log.Printf("Stopping VPN: %s", provider.Name)
	
	if err := s.manager.StopInterface(provider.InterfaceName); err != nil {
		return fmt.Errorf("failed to stop interface: %w", err)
	}
	
	s.mu.Lock()
	delete(s.status, provider.ID)
	s.mu.Unlock()
	
	log.Printf("VPN %s stopped successfully", provider.Name)
	return nil
}

func (s *VPNService) monitorProviders() {
	defer s.wg.Done()
	
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			// Reload providers and check for changes
			keys, err := s.db.List("vpn:provider:")
			if err != nil {
				log.Printf("Failed to list providers: %v", err)
				continue
			}
			
			for _, key := range keys {
				var provider vpn.Provider
				if err := s.db.GetJSON(key, &provider); err != nil {
					continue
				}
				
				s.mu.Lock()
				existing, exists := s.providers[provider.ID]
				s.mu.Unlock()
				
				// Check if provider state changed
				if !exists || existing.Enabled != provider.Enabled || existing.UpdatedAt != provider.UpdatedAt {
					if err := s.ApplyProvider(&provider); err != nil {
						log.Printf("Failed to apply provider %s: %v", provider.Name, err)
					}
				}
			}
		}
	}
}

func (s *VPNService) monitorInterfaces() {
	defer s.wg.Done()
	
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.mu.RLock()
			providers := make([]*vpn.Provider, 0, len(s.providers))
			for _, p := range s.providers {
				if p.Enabled {
					providers = append(providers, p)
				}
			}
			s.mu.RUnlock()
			
			for _, provider := range providers {
				status, err := s.manager.GetInterfaceStatus(provider.InterfaceName)
				if err != nil {
					log.Printf("Failed to get status for %s: %v", provider.Name, err)
					continue
				}
				
				s.mu.Lock()
				s.status[provider.ID] = status
				s.mu.Unlock()
				
				// TODO: Export metrics to monitoring system
				// TODO: Check for connection failures and alert
			}
		}
	}
}