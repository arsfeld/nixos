package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/gorilla/mux"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/crypto"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/modules/vpn"
)

type VPNHandler struct {
	db        *db.DB
	encryptor *crypto.AgeEncryptor
	vpnService interface {
		ApplyProvider(*vpn.Provider) error
		RemoveProvider(string) error
		GetStatus() map[string]*vpn.InterfaceStatus
	}
}

func NewVPNHandler(database *db.DB, encryptor *crypto.AgeEncryptor, vpnService interface {
	ApplyProvider(*vpn.Provider) error
	RemoveProvider(string) error
	GetStatus() map[string]*vpn.InterfaceStatus
}) *VPNHandler {
	return &VPNHandler{
		db:         database,
		encryptor:  encryptor,
		vpnService: vpnService,
	}
}

func (h *VPNHandler) ListProviders(w http.ResponseWriter, r *http.Request) {
	keys, err := h.db.List("vpn:provider:")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	providers := make([]vpn.Provider, 0, len(keys))
	for _, key := range keys {
		var provider vpn.Provider
		if err := h.db.GetJSON(key, &provider); err != nil {
			continue
		}
		providers = append(providers, provider)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(providers)
}

func (h *VPNHandler) GetProvider(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id := vars["id"]

	var provider vpn.Provider
	key := fmt.Sprintf("vpn:provider:%s", id)
	if err := h.db.GetJSON(key, &provider); err != nil {
		http.Error(w, "Provider not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(provider)
}

func (h *VPNHandler) CreateProvider(w http.ResponseWriter, r *http.Request) {
	var provider vpn.Provider
	if err := json.NewDecoder(r.Body).Decode(&provider); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Validate provider
	if err := h.validateProvider(&provider); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Encrypt sensitive fields if present
	if provider.PrivateKey != "" && h.encryptor != nil {
		encrypted, err := h.encryptor.Encrypt([]byte(provider.PrivateKey))
		if err != nil {
			http.Error(w, "Failed to encrypt private key", http.StatusInternalServerError)
			return
		}
		provider.PrivateKey = encrypted
	}

	if provider.PresharedKey != "" && h.encryptor != nil {
		encrypted, err := h.encryptor.Encrypt([]byte(provider.PresharedKey))
		if err != nil {
			http.Error(w, "Failed to encrypt preshared key", http.StatusInternalServerError)
			return
		}
		provider.PresharedKey = encrypted
	}

	provider.ID = generateID()
	provider.CreatedAt = time.Now()
	provider.UpdatedAt = time.Now()

	key := fmt.Sprintf("vpn:provider:%s", provider.ID)
	if err := h.db.SetJSON(key, provider); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Apply the provider configuration if VPN service is available
	if h.vpnService != nil {
		if err := h.vpnService.ApplyProvider(&provider); err != nil {
			log.Printf("Failed to apply VPN provider %s: %v", provider.Name, err)
			// Don't fail the request, just log the error
		}
	}

	// Don't send encrypted keys back to client
	provider.PrivateKey = ""
	provider.PresharedKey = ""

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(provider)
}

func (h *VPNHandler) UpdateProvider(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id := vars["id"]

	var provider vpn.Provider
	if err := json.NewDecoder(r.Body).Decode(&provider); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	provider.ID = id
	provider.UpdatedAt = time.Now()

	key := fmt.Sprintf("vpn:provider:%s", id)
	if err := h.db.SetJSON(key, provider); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(provider)
}

func (h *VPNHandler) DeleteProvider(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id := vars["id"]

	// Remove from VPN service if available
	if h.vpnService != nil {
		if err := h.vpnService.RemoveProvider(id); err != nil {
			log.Printf("Failed to remove VPN provider %s: %v", id, err)
			// Don't fail the request, just log the error
		}
	}

	key := fmt.Sprintf("vpn:provider:%s", id)
	if err := h.db.Delete(key); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *VPNHandler) ToggleProvider(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id := vars["id"]

	var provider vpn.Provider
	key := fmt.Sprintf("vpn:provider:%s", id)
	if err := h.db.GetJSON(key, &provider); err != nil {
		http.Error(w, "Provider not found", http.StatusNotFound)
		return
	}

	provider.Enabled = !provider.Enabled
	provider.UpdatedAt = time.Now()

	if err := h.db.SetJSON(key, provider); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Apply the provider configuration if VPN service is available
	if h.vpnService != nil {
		if err := h.vpnService.ApplyProvider(&provider); err != nil {
			log.Printf("Failed to toggle VPN provider %s: %v", provider.Name, err)
			// Don't fail the request, just log the error
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(provider)
}

func generateID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

func (h *VPNHandler) validateProvider(provider *vpn.Provider) error {
	// Common validation
	if provider.Name == "" {
		return fmt.Errorf("provider name is required")
	}
	
	if provider.Type == "" {
		return fmt.Errorf("provider type is required")
	}
	
	// Type-specific validation
	switch provider.Type {
	case "wireguard":
		if provider.Endpoint == "" {
			return fmt.Errorf("endpoint is required for WireGuard")
		}
		if err := vpn.ValidateEndpoint(provider.Endpoint); err != nil {
			return fmt.Errorf("invalid endpoint: %w", err)
		}
		if provider.PublicKey == "" {
			return fmt.Errorf("public key is required for WireGuard")
		}
		if provider.PrivateKey == "" {
			return fmt.Errorf("private key is required for WireGuard")
		}
		// Generate interface name if not provided
		if provider.InterfaceName == "" {
			provider.InterfaceName = vpn.GenerateInterfaceName(provider.Name)
		}
		// Set default config values
		if provider.Config == nil {
			provider.Config = make(map[string]string)
		}
		if _, ok := provider.Config["table"]; !ok {
			// Assign a unique routing table number (100 + provider number)
			provider.Config["table"] = fmt.Sprintf("%d", 100+time.Now().Unix()%100)
		}
		if _, ok := provider.Config["fwmark"]; !ok {
			// Assign a unique firewall mark
			provider.Config["fwmark"] = fmt.Sprintf("%d", 100+time.Now().Unix()%100)
		}
	case "openvpn":
		return fmt.Errorf("OpenVPN support not yet implemented")
	default:
		return fmt.Errorf("unsupported provider type: %s", provider.Type)
	}
	
	return nil
}

// GetVPNStatus returns the status of all VPN interfaces
func (h *VPNHandler) GetVPNStatus(w http.ResponseWriter, r *http.Request) {
	if h.vpnService == nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{})
		return
	}

	status := h.vpnService.GetStatus()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}