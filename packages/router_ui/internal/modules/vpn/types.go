package vpn

import "time"

type Provider struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	Type          string            `json:"type"` // "wireguard", "openvpn"
	Config        map[string]string `json:"config"`
	Enabled       bool              `json:"enabled"`
	InterfaceName string            `json:"interface_name"` // e.g., "wg-pia"
	Endpoint      string            `json:"endpoint"`
	PublicKey     string            `json:"public_key"`
	PrivateKey    string            `json:"private_key"`
	PresharedKey  string            `json:"preshared_key"`
	CreatedAt     time.Time         `json:"created_at"`
	UpdatedAt     time.Time         `json:"updated_at"`
}

type ClientMapping struct {
	ID             string    `json:"id"`
	ClientMAC      string    `json:"client_mac"`
	ClientIP       string    `json:"client_ip"`
	ClientHostname string    `json:"client_hostname"`
	ProviderID     string    `json:"provider_id"`
	Enabled        bool      `json:"enabled"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}