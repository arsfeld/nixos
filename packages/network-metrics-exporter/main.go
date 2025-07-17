package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// Metrics
	clientTrafficBytes = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_traffic_bytes",
		Help: "Current traffic counter value per client in bytes",
	}, []string{"direction", "ip", "client"})

	clientTrafficRateBps = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_traffic_rate_bps",
		Help: "Current traffic rate per client in bits per second",
	}, []string{"direction", "ip", "client"})

	clientActiveConnections = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_active_connections",
		Help: "Number of active connections per client",
	}, []string{"ip", "client"})

	clientStatus = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_status",
		Help: "Client online status (1=online, 0=offline)",
	}, []string{"ip", "client"})

	// Internal tracking
	clients     = make(map[string]*ClientInfo)
	clientsLock sync.RWMutex
	
	// Traffic tracking for rate calculation
	trafficHistory     = make(map[string]*TrafficSnapshot)
	trafficHistoryLock sync.RWMutex
	
	// Client name cache that persists across restarts
	clientNameCache     = make(map[string]string)
	clientNameCacheLock sync.RWMutex
	clientNameCacheFile = "/var/lib/network-metrics-exporter/client-names.cache"
)

type ClientInfo struct {
	IP            string
	Name          string
	LastSeen      time.Time
}

type TrafficSnapshot struct {
	RxBytes   uint64
	TxBytes   uint64
	Timestamp time.Time
}

type NftRule struct {
	Comment string `json:"comment"`
	Expr    []struct {
		Counter *struct {
			Bytes uint64 `json:"bytes"`
		} `json:"counter,omitempty"`
	} `json:"expr"`
}

type NftOutput struct {
	Nftables []struct {
		Rule *NftRule `json:"rule,omitempty"`
	} `json:"nftables"`
}

func main() {
	// Load client name cache
	loadClientNameCache()
	
	// Get configuration from environment
	port := os.Getenv("METRICS_PORT")
	if port == "" {
		port = "9101"
	}
	
	// Start metric collection
	go collectMetrics()

	// Expose metrics endpoint
	http.Handle("/metrics", promhttp.Handler())
	addr := ":" + port
	log.Printf("Starting network-metrics-exporter on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func collectMetrics() {
	// Get update interval from environment
	intervalStr := os.Getenv("UPDATE_INTERVAL")
	interval := 2
	if intervalStr != "" {
		if i, err := time.ParseDuration(intervalStr + "s"); err == nil {
			interval = int(i.Seconds())
		}
	}
	
	ticker := time.NewTicker(time.Duration(interval) * time.Second)
	defer ticker.Stop()

	for {
		updateMetrics()
		<-ticker.C
	}
}

func updateMetrics() {
	// Update traffic metrics from nftables
	updateTrafficMetrics()

	// Update connection counts
	updateConnectionCounts()

	// Update client status
	updateClientStatus()
}

func updateTrafficMetrics() {
	cmd := exec.Command("nft", "-j", "list", "chain", "inet", "filter", "CLIENT_TRAFFIC")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Error getting nftables rules: %v", err)
		return
	}

	var nftOutput NftOutput
	if err := json.Unmarshal(output, &nftOutput); err != nil {
		log.Printf("Error parsing nftables JSON: %v", err)
		return
	}

	re := regexp.MustCompile(`^(tx|rx)_(\d+\.\d+\.\d+\.\d+)$`)
	currentTime := time.Now()
	
	// Track current values per IP
	currentTraffic := make(map[string]*TrafficSnapshot)

	clientsLock.Lock()
	defer clientsLock.Unlock()

	for _, item := range nftOutput.Nftables {
		if item.Rule == nil || item.Rule.Comment == "" {
			continue
		}

		matches := re.FindStringSubmatch(item.Rule.Comment)
		if len(matches) != 3 {
			continue
		}

		direction := matches[1]
		ip := matches[2]

		var bytes uint64
		for _, expr := range item.Rule.Expr {
			if expr.Counter != nil {
				bytes = expr.Counter.Bytes
				break
			}
		}

		client, exists := clients[ip]
		
		if !exists {
			clientName := getClientName(ip)
			client = &ClientInfo{
				IP:       ip,
				Name:     clientName,
				LastSeen: currentTime,
			}
			clients[ip] = client
		}

		// Report the current byte count
		clientTrafficBytes.WithLabelValues(direction, ip, client.Name).Set(float64(bytes))
		client.LastSeen = currentTime
		
		// Update current traffic snapshot
		if currentTraffic[ip] == nil {
			currentTraffic[ip] = &TrafficSnapshot{Timestamp: currentTime}
		}
		if direction == "rx" {
			currentTraffic[ip].RxBytes = bytes
		} else {
			currentTraffic[ip].TxBytes = bytes
		}
	}
	
	// Calculate rates
	trafficHistoryLock.Lock()
	defer trafficHistoryLock.Unlock()
	
	for ip, current := range currentTraffic {
		client := clients[ip]
		previous, exists := trafficHistory[ip]
		
		if exists && previous.Timestamp.Before(currentTime) {
			timeDiff := currentTime.Sub(previous.Timestamp).Seconds()
			if timeDiff > 0 {
				// Calculate rates in bits per second
				rxRate := float64(current.RxBytes-previous.RxBytes) * 8 / timeDiff
				txRate := float64(current.TxBytes-previous.TxBytes) * 8 / timeDiff
				
				// Only set positive rates (handle counter resets)
				if rxRate >= 0 {
					clientTrafficRateBps.WithLabelValues("rx", ip, client.Name).Set(rxRate)
				}
				if txRate >= 0 {
					clientTrafficRateBps.WithLabelValues("tx", ip, client.Name).Set(txRate)
				}
			}
		} else {
			// First reading, set rate to 0
			clientTrafficRateBps.WithLabelValues("rx", ip, client.Name).Set(0)
			clientTrafficRateBps.WithLabelValues("tx", ip, client.Name).Set(0)
		}
		
		// Update history
		trafficHistory[ip] = current
	}
	
	// Clear rates for clients that are no longer active
	for ip, previous := range trafficHistory {
		if _, exists := currentTraffic[ip]; !exists {
			if currentTime.Sub(previous.Timestamp) > 30*time.Second {
				client := clients[ip]
				clientTrafficRateBps.WithLabelValues("rx", ip, client.Name).Set(0)
				clientTrafficRateBps.WithLabelValues("tx", ip, client.Name).Set(0)
			}
		}
	}
}

func updateConnectionCounts() {
	cmd := exec.Command("conntrack", "-L", "-o", "extended")
	output, err := cmd.Output()
	if err != nil {
		// conntrack might return error if no connections
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// No connections, clear all metrics
			clientActiveConnections.Reset()
			return
		}
		log.Printf("Error getting conntrack data: %v", err)
		return
	}

	// Count connections per IP
	connectionCounts := make(map[string]int)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	
	for scanner.Scan() {
		line := scanner.Text()
		// Extract IPs from conntrack output
		// Look for src= and dst= patterns
		re := regexp.MustCompile(`\b(?:src|dst)=(\d+\.\d+\.\d+\.\d+)\b`)
		matches := re.FindAllStringSubmatch(line, -1)
		
		for _, match := range matches {
			ip := match[1]
			// Only count local network IPs
			if strings.HasPrefix(ip, "192.168.10.") {
				connectionCounts[ip]++
			}
		}
	}

	clientsLock.RLock()
	defer clientsLock.RUnlock()

	// Reset metrics first
	clientActiveConnections.Reset()

	// Update metrics for known clients
	for ip, client := range clients {
		count := connectionCounts[ip]
		clientActiveConnections.WithLabelValues(ip, client.Name).Set(float64(count))
	}
}

func updateClientStatus() {
	// Get ARP table
	cmd := exec.Command("ip", "neigh", "show")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Error getting ARP table: %v", err)
		return
	}

	// Parse ARP entries
	arpEntries := make(map[string]bool)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	
	for scanner.Scan() {
		line := scanner.Text()
		// Look for REACHABLE, STALE, DELAY, or PROBE states
		if strings.Contains(line, "REACHABLE") || 
		   strings.Contains(line, "STALE") || 
		   strings.Contains(line, "DELAY") || 
		   strings.Contains(line, "PROBE") {
			fields := strings.Fields(line)
			if len(fields) > 0 {
				ip := fields[0]
				if strings.HasPrefix(ip, "192.168.10.") {
					arpEntries[ip] = true
				}
			}
		}
	}

	clientsLock.RLock()
	defer clientsLock.RUnlock()

	// Update status for all known clients
	for ip, client := range clients {
		status := 0.0
		if arpEntries[ip] {
			status = 1.0
		}
		clientStatus.WithLabelValues(ip, client.Name).Set(status)
	}
}

func getClientName(ip string) string {
	// Check cache first
	clientNameCacheLock.RLock()
	if cachedName, exists := clientNameCache[ip]; exists {
		clientNameCacheLock.RUnlock()
		return cachedName
	}
	clientNameCacheLock.RUnlock()

	// Try dhcp-hosts file first (format: IP hostname hostname.lan)
	if name := getNameFromDhcpHosts("/var/lib/dnsmasq/dhcp-hosts", ip); name != "" {
		updateClientNameCache(ip, name)
		return name
	}

	// Try dnsmasq leases file (format: timestamp MAC IP hostname *)
	if name := getNameFromFile("/var/lib/dnsmasq/dnsmasq.leases", ip, 2, 3); name != "" {
		updateClientNameCache(ip, name)
		return name
	}

	// Try reverse DNS lookup as fallback
	if name := getNameFromReverseDNS(ip); name != "" {
		updateClientNameCache(ip, name)
		return name
	}

	return "unknown"
}

func getNameFromDhcpHosts(filename, ip string) string {
	file, err := os.Open(filename)
	if err != nil {
		return ""
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		// Skip comments and empty lines
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		
		fields := strings.Fields(line)
		// Format: IP hostname hostname.lan
		if len(fields) >= 2 && fields[0] == ip {
			// Return the first hostname without .lan suffix
			return strings.TrimSuffix(fields[1], ".lan")
		}
	}
	return ""
}

func getNameFromFile(filename, ip string, ipCol, nameCol int) string {
	file, err := os.Open(filename)
	if err != nil {
		return ""
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) > max(ipCol, nameCol) {
			if fields[ipCol] == ip && fields[nameCol] != "*" {
				return fields[nameCol]
			}
		}
	}
	return ""
}

func getNameFromReverseDNS(ip string) string {
	// Try reverse DNS lookup with a short timeout
	names, err := net.LookupAddr(ip)
	if err != nil || len(names) == 0 {
		return ""
	}
	
	// Use the first name, remove trailing dot and .lan suffix
	name := strings.TrimSuffix(names[0], ".")
	name = strings.TrimSuffix(name, ".lan")
	
	// If it's just an IP-based name, ignore it
	if strings.Contains(name, ip) {
		return ""
	}
	
	return name
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func loadClientNameCache() {
	// Create directory if it doesn't exist
	dir := "/var/lib/network-metrics-exporter"
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("Error creating cache directory: %v", err)
		return
	}
	
	data, err := os.ReadFile(clientNameCacheFile)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("Error reading client name cache: %v", err)
		}
		return
	}
	
	clientNameCacheLock.Lock()
	defer clientNameCacheLock.Unlock()
	
	// Parse cache file (format: IP|Name per line)
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		parts := strings.Split(scanner.Text(), "|")
		if len(parts) == 2 {
			clientNameCache[parts[0]] = parts[1]
		}
	}
	
	log.Printf("Loaded %d client names from cache", len(clientNameCache))
}

func updateClientNameCache(ip, name string) {
	clientNameCacheLock.Lock()
	clientNameCache[ip] = name
	clientNameCacheLock.Unlock()
	
	// Save cache asynchronously
	go saveClientNameCache()
}

func saveClientNameCache() {
	clientNameCacheLock.RLock()
	defer clientNameCacheLock.RUnlock()
	
	var lines []string
	for ip, name := range clientNameCache {
		lines = append(lines, ip+"|"+name)
	}
	
	data := strings.Join(lines, "\n")
	
	// Write atomically
	tmpFile := clientNameCacheFile + ".tmp"
	if err := os.WriteFile(tmpFile, []byte(data), 0644); err != nil {
		log.Printf("Error writing client name cache: %v", err)
		return
	}
	
	if err := os.Rename(tmpFile, clientNameCacheFile); err != nil {
		log.Printf("Error renaming client name cache: %v", err)
	}
}
