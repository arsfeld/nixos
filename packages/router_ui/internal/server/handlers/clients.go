package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/gorilla/mux"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/modules/clients"
)

type ClientHandler struct {
	db *db.DB
}

func NewClientHandler(database *db.DB) *ClientHandler {
	return &ClientHandler{db: database}
}

func (h *ClientHandler) ListClients(w http.ResponseWriter, r *http.Request) {
	clientList := clients.DiscoverClients()
	
	for i := range clientList {
		key := fmt.Sprintf("client:mapping:%s", clientList[i].MAC)
		var mapping clients.ClientVPNMapping
		if err := h.db.GetJSON(key, &mapping); err == nil {
			clientList[i].VPNProviderID = mapping.ProviderID
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(clientList)
}

func (h *ClientHandler) UpdateVPNMapping(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	mac := vars["mac"]

	var mapping clients.ClientVPNMapping
	if err := json.NewDecoder(r.Body).Decode(&mapping); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	mapping.ClientMAC = mac
	key := fmt.Sprintf("client:mapping:%s", mac)
	
	if mapping.ProviderID == "" {
		if err := h.db.Delete(key); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	} else {
		if err := h.db.SetJSON(key, mapping); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(mapping)
}