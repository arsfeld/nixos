package clients

import "time"

type Client struct {
	MAC           string    `json:"mac"`
	IP            string    `json:"ip"`
	Hostname      string    `json:"hostname"`
	VPNProviderID string    `json:"vpn_provider_id,omitempty"`
	LastSeen      time.Time `json:"last_seen"`
}

type ClientVPNMapping struct {
	ClientMAC  string `json:"client_mac"`
	ProviderID string `json:"provider_id"`
}