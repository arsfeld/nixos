package config

import (
	"encoding/json"
	"os"
)

type Config struct {
	Port          string `json:"port"`
	DBPath        string `json:"db_path"`
	StaticDir     string `json:"static_dir"`
	TemplatesDir  string `json:"templates_dir"`
	TailscaleAuth bool   `json:"tailscale_auth"`
	EnableVPN     bool   `json:"enable_vpn"`
}

func (c *Config) LoadFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, c)
}

func (c *Config) SetDefaults() {
	if c.Port == "" {
		c.Port = "4000"
	}
	if c.DBPath == "" {
		c.DBPath = "/var/lib/router-ui/db"
	}
	if c.StaticDir == "" {
		c.StaticDir = getEnvOrDefault("ROUTER_UI_STATIC_DIR", "web/static")
	}
	if c.TemplatesDir == "" {
		c.TemplatesDir = getEnvOrDefault("ROUTER_UI_TEMPLATES_DIR", "web/templates")
	}
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}