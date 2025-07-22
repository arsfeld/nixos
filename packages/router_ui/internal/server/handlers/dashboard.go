package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"

	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
)

type DashboardHandler struct {
	db *db.DB
}

func NewDashboardHandler(database *db.DB) *DashboardHandler {
	return &DashboardHandler{db: database}
}

type DashboardStats struct {
	ActiveVPNs       int                    `json:"active_vpns"`
	TotalVPNs        int                    `json:"total_vpns"`
	ConnectedClients int                    `json:"connected_clients"`
	SystemHealth     SystemHealth           `json:"system_health"`
	TrafficStats     map[string]TrafficStat `json:"traffic_stats"`
}

type SystemHealth struct {
	CPUUsage    float64 `json:"cpu_usage"`
	MemoryUsage float64 `json:"memory_usage"`
	Uptime      int64   `json:"uptime"`
}

type TrafficStat struct {
	BytesSent     int64 `json:"bytes_sent"`
	BytesReceived int64 `json:"bytes_received"`
}

func (h *DashboardHandler) GetStats(w http.ResponseWriter, r *http.Request) {
	stats := DashboardStats{
		TrafficStats: make(map[string]TrafficStat),
	}

	// Count total VPN providers
	providerKeys, err := h.db.List("vpn:provider:")
	if err == nil {
		stats.TotalVPNs = len(providerKeys)
	}

	// Count active VPN connections
	stats.ActiveVPNs = h.countActiveVPNs()

	// Count connected clients
	stats.ConnectedClients = h.countConnectedClients()

	// Get system health
	stats.SystemHealth = h.getSystemHealth()

	// Get traffic statistics for each interface
	stats.TrafficStats = h.getTrafficStats()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

func (h *DashboardHandler) countActiveVPNs() int {
	// Check WireGuard interfaces
	cmd := exec.Command("wg", "show", "interfaces")
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	interfaces := strings.Fields(string(output))
	activeCount := 0
	for _, iface := range interfaces {
		if strings.HasPrefix(iface, "wg-") {
			activeCount++
		}
	}

	return activeCount
}

func (h *DashboardHandler) countConnectedClients() int {
	// Count DHCP leases (simplified)
	cmd := exec.Command("wc", "-l", "/var/lib/kea/dhcp4.leases")
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	count := 0
	fields := strings.Fields(string(output))
	if len(fields) > 0 {
		// Parse the count, ignoring errors
		fmt.Sscanf(fields[0], "%d", &count)
	}

	return count
}

func (h *DashboardHandler) getSystemHealth() SystemHealth {
	health := SystemHealth{}

	// Get CPU usage (simplified - reads from /proc/stat)
	// In production, you'd want to calculate this properly
	health.CPUUsage = 0.0

	// Get memory usage
	cmd := exec.Command("free", "-b")
	output, err := cmd.Output()
	if err == nil {
		lines := strings.Split(string(output), "\n")
		if len(lines) > 1 {
			// Parse memory line
			fields := strings.Fields(lines[1])
			if len(fields) >= 3 {
				var total, used float64
				fmt.Sscanf(fields[1], "%f", &total)
				fmt.Sscanf(fields[2], "%f", &used)
				if total > 0 {
					health.MemoryUsage = (used / total) * 100
				}
			}
		}
	}

	// Get uptime
	cmd = exec.Command("cat", "/proc/uptime")
	output, err = cmd.Output()
	if err == nil {
		fields := strings.Fields(string(output))
		if len(fields) > 0 {
			fmt.Sscanf(fields[0], "%d", &health.Uptime)
		}
	}

	return health
}

func (h *DashboardHandler) getTrafficStats() map[string]TrafficStat {
	stats := make(map[string]TrafficStat)

	// Get WireGuard interfaces
	cmd := exec.Command("wg", "show", "interfaces")
	output, err := cmd.Output()
	if err != nil {
		return stats
	}

	interfaces := strings.Fields(string(output))
	for _, iface := range interfaces {
		// Get transfer stats for each interface
		cmd := exec.Command("wg", "show", iface, "transfer")
		output, err := cmd.Output()
		if err != nil {
			continue
		}

		lines := strings.Split(string(output), "\n")
		for _, line := range lines {
			fields := strings.Fields(line)
			if len(fields) >= 3 {
				// Format: peer rx tx
				var rx, tx int64
				fmt.Sscanf(fields[1], "%d", &rx)
				fmt.Sscanf(fields[2], "%d", &tx)
				
				stats[iface] = TrafficStat{
					BytesReceived: rx,
					BytesSent:     tx,
				}
			}
		}
	}

	return stats
}