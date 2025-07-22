package handlers

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gorilla/mux"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/services"
)

// ClientHandlerV2 handles client-related HTTP requests using the discovery service
type ClientHandlerV2 struct {
	discoveryService *services.ClientDiscoveryService
}

// NewClientHandlerV2 creates a new client handler
func NewClientHandlerV2(discoveryService *services.ClientDiscoveryService) *ClientHandlerV2 {
	return &ClientHandlerV2{
		discoveryService: discoveryService,
	}
}

// ListClients returns all discovered clients
func (h *ClientHandlerV2) ListClients(w http.ResponseWriter, r *http.Request) {
	if h.discoveryService == nil {
		http.Error(w, "Client discovery service not available", http.StatusServiceUnavailable)
		return
	}
	
	clients := h.discoveryService.GetClients()
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(clients)
}

// GetClient returns a specific client
func (h *ClientHandlerV2) GetClient(w http.ResponseWriter, r *http.Request) {
	if h.discoveryService == nil {
		http.Error(w, "Client discovery service not available", http.StatusServiceUnavailable)
		return
	}
	
	vars := mux.Vars(r)
	mac := vars["mac"]
	
	client, exists := h.discoveryService.GetClient(mac)
	if !exists {
		http.Error(w, "Client not found", http.StatusNotFound)
		return
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(client)
}

// UpdateClient updates client information
func (h *ClientHandlerV2) UpdateClient(w http.ResponseWriter, r *http.Request) {
	if h.discoveryService == nil {
		http.Error(w, "Client discovery service not available", http.StatusServiceUnavailable)
		return
	}
	
	vars := mux.Vars(r)
	mac := vars["mac"]
	
	var updates map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&updates); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	
	if err := h.discoveryService.UpdateClient(mac, updates); err != nil {
		if strings.Contains(err.Error(), "not found") {
			http.Error(w, err.Error(), http.StatusNotFound)
		} else {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}
	
	// Return updated client
	client, _ := h.discoveryService.GetClient(mac)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(client)
}

// GetClientStats returns statistics about clients
func (h *ClientHandlerV2) GetClientStats(w http.ResponseWriter, r *http.Request) {
	if h.discoveryService == nil {
		http.Error(w, "Client discovery service not available", http.StatusServiceUnavailable)
		return
	}
	
	clients := h.discoveryService.GetClients()
	
	stats := struct {
		Total        int            `json:"total"`
		Online       int            `json:"online"`
		ByDeviceType map[string]int `json:"by_device_type"`
		ByManufacturer map[string]int `json:"by_manufacturer"`
	}{
		Total:          len(clients),
		ByDeviceType:   make(map[string]int),
		ByManufacturer: make(map[string]int),
	}
	
	for _, client := range clients {
		if client.Online {
			stats.Online++
		}
		
		stats.ByDeviceType[client.DeviceType]++
		
		if client.Manufacturer != "" && client.Manufacturer != "Unknown" {
			stats.ByManufacturer[client.Manufacturer]++
		}
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}