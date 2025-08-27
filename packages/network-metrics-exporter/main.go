package main

import (
	"bufio"
	"context"
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

	"github.com/grandcat/zeroconf"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/wimark/vendormap"
)

var (
	// Metrics
	clientTrafficBytes = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_traffic_bytes",
		Help: "Current traffic counter value per client in bytes",
	}, []string{"direction", "ip", "client", "device_type"})

	clientTrafficRateBps = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_traffic_rate_bps",
		Help: "Current traffic rate per client in bits per second",
	}, []string{"direction", "ip", "client", "device_type"})

	clientActiveConnections = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_active_connections",
		Help: "Number of active connections per client",
	}, []string{"ip", "client", "device_type"})

	clientStatus = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_status",
		Help: "Client online status (1=online, 0=offline)",
	}, []string{"ip", "client", "device_type"})

	wanIpInfo = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "wan_ip_info",
		Help: "WAN IP address information",
	}, []string{"interface", "ip"})

	// Internal tracking
	clients     = make(map[string]*ClientInfo)
	clientsLock sync.RWMutex
	
	// Compiled regex patterns for performance
	trafficRuleRegex = regexp.MustCompile(`^(tx|rx)_(\d+\.\d+\.\d+\.\d+)$`)
	conntrackIPRegex = regexp.MustCompile(`\b(?:src|dst)=(\d+\.\d+\.\d+\.\d+)\b`)
	
	// WAN interface name from environment
	wanInterface = os.Getenv("WAN_INTERFACE")
	
	// Traffic tracking for rate calculation
	trafficHistory     = make(map[string]*TrafficSnapshot)
	trafficHistoryLock sync.RWMutex
	
	// Client name cache that persists across restarts
	clientNameCache     = make(map[string]string)
	clientNameCacheLock sync.RWMutex
	clientNameCacheFile = "/var/lib/network-metrics-exporter/client-names.cache"
	
	// Client database metrics
	clientsTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "network_clients_total",
		Help: "Total number of known network clients",
	})
	
	clientsOnline = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "network_clients_online",
		Help: "Number of online clients",
	})
	
	clientsByType = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "network_clients_by_type",
		Help: "Number of clients by device type",
	}, []string{"type"})
	
	// ARP scan cache
	arpScanCache     = make(map[string]*ArpScanEntry)
	arpScanCacheLock sync.RWMutex
	lastArpScan      time.Time
	
	// mDNS cache
	mdnsCache     = make(map[string]*MDNSEntry)
	mdnsCacheLock sync.RWMutex
	lastMDNSScan  time.Time
	
	// DNS resolution queue for background processing
	dnsResolveQueue = make(chan string, 100)
	dnsResolveCache = make(map[string]string)
	dnsResolveCacheLock sync.RWMutex
)

type ClientInfo struct {
	IP            string
	Name          string
	DeviceType    string
	LastSeen      time.Time
}

type TrafficSnapshot struct {
	RxBytes   uint64
	TxBytes   uint64
	Timestamp time.Time
}

type ClientDBEntry struct {
	MAC        string `json:"mac"`
	Hostname   string `json:"hostname"`
	IP         string `json:"ip"`
	DeviceType string `json:"deviceType"`
	LastSeen   string `json:"lastSeen"`
}

type ArpScanEntry struct {
	IP       string
	MAC      string
	Vendor   string
	LastSeen time.Time
}

type MDNSEntry struct {
	IP           string
	Hostname     string
	Instance     string
	Service      string
	Domain       string
	DeviceType   string // Inferred from service type
	LastSeen     time.Time
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
	
	// Start background DNS resolver
	go backgroundDNSResolver()
	
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
	
	// Start background discovery tasks with their own timers
	go runPeriodicArpScan()
	go runPeriodicMDNSDiscovery()
	
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
	
	// Update WAN IP
	updateWanIp()
	
	// Update client database metrics
	updateClientDatabaseMetrics()
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

	currentTime := time.Now()
	
	// Track current values per IP
	currentTraffic := make(map[string]*TrafficSnapshot)

	clientsLock.Lock()
	defer clientsLock.Unlock()

	for _, item := range nftOutput.Nftables {
		if item.Rule == nil || item.Rule.Comment == "" {
			continue
		}

		matches := trafficRuleRegex.FindStringSubmatch(item.Rule.Comment)
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
			macAddr := getMacAddress(ip)
			deviceType := "unknown"
			
			// Try to get device type from client database first
			clientDB := loadClientDatabase()
			if dbEntry, ok := clientDB[ip]; ok {
				if dbEntry.Hostname != "" && clientName == "unknown" {
					clientName = dbEntry.Hostname
				}
				if dbEntry.DeviceType != "" {
					deviceType = dbEntry.DeviceType
				}
			}
			
			// If device type is still unknown, try to infer it
			if deviceType == "unknown" {
				// Check mDNS cache first
				mdnsCacheLock.RLock()
				if mdnsEntry, exists := mdnsCache[ip]; exists && mdnsEntry.DeviceType != "" && mdnsEntry.DeviceType != "unknown" {
					deviceType = mdnsEntry.DeviceType
				}
				mdnsCacheLock.RUnlock()
				
				// If still unknown, use inference
				if deviceType == "unknown" {
					vendor := getVendorForIP(ip)
					deviceType = inferDeviceType(clientName, macAddr, vendor)
				}
			}
			
			client = &ClientInfo{
				IP:         ip,
				Name:       clientName,
				DeviceType: deviceType,
				LastSeen:   currentTime,
			}
			clients[ip] = client
		} else {
			// Update device type if it was unknown and we can now infer it
			if client.DeviceType == "unknown" {
				macAddr := getMacAddress(ip)
				vendor := getVendorForIP(ip)
				newType := inferDeviceType(client.Name, macAddr, vendor)
				if newType != "unknown" {
					client.DeviceType = newType
				}
			}
		}

		// Report the current byte count
		clientTrafficBytes.WithLabelValues(direction, ip, client.Name, client.DeviceType).Set(float64(bytes))
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
					clientTrafficRateBps.WithLabelValues("rx", ip, client.Name, client.DeviceType).Set(rxRate)
				}
				if txRate >= 0 {
					clientTrafficRateBps.WithLabelValues("tx", ip, client.Name, client.DeviceType).Set(txRate)
				}
			}
		} else {
			// First reading, set rate to 0
			clientTrafficRateBps.WithLabelValues("rx", ip, client.Name, client.DeviceType).Set(0)
			clientTrafficRateBps.WithLabelValues("tx", ip, client.Name, client.DeviceType).Set(0)
		}
		
		// Update history
		trafficHistory[ip] = current
	}
	
	// Clear rates for clients that are no longer active
	for ip, previous := range trafficHistory {
		if _, exists := currentTraffic[ip]; !exists {
			if currentTime.Sub(previous.Timestamp) > 30*time.Second {
				client := clients[ip]
				clientTrafficRateBps.WithLabelValues("rx", ip, client.Name, client.DeviceType).Set(0)
				clientTrafficRateBps.WithLabelValues("tx", ip, client.Name, client.DeviceType).Set(0)
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
		matches := conntrackIPRegex.FindAllStringSubmatch(line, -1)
		
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
		clientActiveConnections.WithLabelValues(ip, client.Name, client.DeviceType).Set(float64(count))
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
		clientStatus.WithLabelValues(ip, client.Name, client.DeviceType).Set(status)
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

	// Check mDNS cache
	mdnsCacheLock.RLock()
	if mdnsEntry, exists := mdnsCache[ip]; exists {
		mdnsCacheLock.RUnlock()
		// Use instance name if available, otherwise hostname
		name := mdnsEntry.Instance
		if name == "" && mdnsEntry.Hostname != "" {
			// Remove .local. suffix
			name = strings.TrimSuffix(mdnsEntry.Hostname, ".local.")
			name = strings.TrimSuffix(name, ".")
		}
		if name != "" {
			updateClientNameCache(ip, name)
			return name
		}
	} else {
		mdnsCacheLock.RUnlock()
	}

	// Check DNS resolution cache
	dnsResolveCacheLock.RLock()
	if resolvedName, exists := dnsResolveCache[ip]; exists {
		dnsResolveCacheLock.RUnlock()
		if resolvedName != "" {
			updateClientNameCache(ip, resolvedName)
			return resolvedName
		}
	} else {
		dnsResolveCacheLock.RUnlock()
		// Queue for background resolution
		select {
		case dnsResolveQueue <- ip:
		default:
			// Queue is full, skip
		}
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

func updateClientNameCache(ip, name string) {
	clientNameCacheLock.Lock()
	clientNameCache[ip] = name
	clientNameCacheLock.Unlock()
	
	// Save cache in background
	go saveClientNameCache()
}

// inferDeviceType tries to determine device type from hostname, MAC address, and vendor
func inferDeviceType(hostname string, macAddr string, vendor string) string {
	// Convert hostname and vendor to lowercase for pattern matching
	lowerHostname := strings.ToLower(hostname)
	lowerVendor := strings.ToLower(vendor)
	
	// Check hostname patterns
	switch {
	// Apple devices
	case strings.Contains(lowerHostname, "macbook"), strings.Contains(lowerHostname, "imac"):
		return "laptop"
	case strings.Contains(lowerHostname, "iphone"):
		return "phone"
	case strings.Contains(lowerHostname, "ipad"):
		return "tablet"
	case strings.Contains(lowerHostname, "apple-tv"), strings.Contains(lowerHostname, "appletv"):
		return "media"
		
	// Google devices
	case strings.Contains(lowerHostname, "google-home"), strings.Contains(lowerHostname, "nest-mini"):
		return "iot"
	case strings.Contains(lowerHostname, "chromecast"):
		return "media"
		
	// Smart home devices
	case strings.HasPrefix(lowerHostname, "hs"), strings.HasPrefix(lowerHostname, "ks"), // TP-Link smart switches
		strings.Contains(lowerHostname, "tapo"),
		strings.Contains(lowerHostname, "myq"), // Garage door openers
		strings.Contains(lowerHostname, "ring"),
		strings.Contains(lowerHostname, "hue"),
		strings.Contains(lowerHostname, "wemo"),
		strings.Contains(lowerHostname, "smartthings"):
		return "iot"
		
	// Media devices
	case strings.Contains(lowerHostname, "roku"),
		strings.Contains(lowerHostname, "firetv"), strings.Contains(lowerHostname, "fire-tv"),
		strings.Contains(lowerHostname, "shield"), // NVIDIA Shield
		strings.Contains(lowerHostname, "vizio"),
		strings.Contains(lowerHostname, "samsung-tv"), strings.Contains(lowerHostname, "lg-tv"):
		return "media"
		
	// Gaming consoles
	case strings.Contains(lowerHostname, "playstation"), strings.Contains(lowerHostname, "ps4"), strings.Contains(lowerHostname, "ps5"),
		strings.Contains(lowerHostname, "xbox"),
		strings.Contains(lowerHostname, "nintendo"), strings.Contains(lowerHostname, "switch"):
		return "gaming"
		
	// Printers
	case strings.Contains(lowerHostname, "printer"),
		strings.HasPrefix(lowerHostname, "hp"), strings.Contains(lowerHostname, "officejet"),
		strings.Contains(lowerHostname, "brother"),
		strings.Contains(lowerHostname, "canon"),
		strings.Contains(lowerHostname, "epson"):
		return "printer"
		
	// Phones
	case strings.Contains(lowerHostname, "android"), strings.Contains(lowerHostname, "phone"),
		strings.Contains(lowerHostname, "pixel"), strings.Contains(lowerHostname, "galaxy"):
		return "phone"
		
	// Network equipment
	case strings.Contains(lowerHostname, "switch"), strings.Contains(lowerHostname, "router"),
		strings.Contains(lowerHostname, "ap-"), strings.Contains(lowerHostname, "unifi"):
		return "network"
		
	// Computers
	case strings.Contains(lowerHostname, "desktop"), strings.Contains(lowerHostname, "laptop"),
		strings.Contains(lowerHostname, "pc-"), strings.Contains(lowerHostname, "workstation"):
		return "computer"
	}
	
	// Check vendor information from arp-scan
	if vendor != "" {
		switch {
		// Apple devices
		case strings.Contains(lowerVendor, "apple"):
			if strings.Contains(lowerHostname, "iphone") {
				return "phone"
			} else if strings.Contains(lowerHostname, "ipad") {
				return "tablet"
			} else if strings.Contains(lowerHostname, "appletv") || strings.Contains(lowerHostname, "apple-tv") {
				return "media"
			}
			return "computer"
			
		// Amazon devices
		case strings.Contains(lowerVendor, "amazon"):
			return "media" // Fire TV, Echo Show, etc.
			
		// Google devices
		case strings.Contains(lowerVendor, "google"):
			return "iot" // Google Home, Nest devices
			
		// Smart home manufacturers
		case strings.Contains(lowerVendor, "belkin"), // Wemo
			strings.Contains(lowerVendor, "tp-link"),
			strings.Contains(lowerVendor, "tuya"),
			strings.Contains(lowerVendor, "espressif"), // ESP8266/ESP32 IoT devices
			strings.Contains(lowerVendor, "azurewave"): // Common in IoT devices
			return "iot"
			
		// Network equipment
		case strings.Contains(lowerVendor, "ubiquiti"),
			strings.Contains(lowerVendor, "cisco"),
			strings.Contains(lowerVendor, "netgear"),
			strings.Contains(lowerVendor, "asus"),
			strings.Contains(lowerVendor, "d-link"):
			return "network"
			
		// Gaming consoles
		case strings.Contains(lowerVendor, "sony interactive"), // PlayStation
			strings.Contains(lowerVendor, "microsoft"), // Xbox
			strings.Contains(lowerVendor, "nintendo"):
			return "gaming"
			
		// Printers
		case strings.Contains(lowerVendor, "hewlett packard") || strings.Contains(lowerVendor, "hp inc"),
			strings.Contains(lowerVendor, "canon"),
			strings.Contains(lowerVendor, "epson"),
			strings.Contains(lowerVendor, "brother"):
			return "printer"
			
		// Media devices
		case strings.Contains(lowerVendor, "roku"),
			strings.Contains(lowerVendor, "samsung electronics"), // Often TVs
			strings.Contains(lowerVendor, "lg electronics"): // Often TVs
			return "media"
		}
	}
	
	// Check MAC OUI using proper database
	if macAddr != "" && vendor == "" {
		// Get vendor from OUI database
		vendorFromDB := vendormap.MACVendor(macAddr)
		if vendorFromDB != "" {
			vendor = vendorFromDB
			lowerVendor = strings.ToLower(vendor)
			
			// Re-run vendor-based device type detection with OUI vendor
			switch {
			// Apple devices
			case strings.Contains(lowerVendor, "apple"):
				if strings.Contains(lowerHostname, "iphone") {
					return "phone"
				} else if strings.Contains(lowerHostname, "ipad") {
					return "tablet"
				} else if strings.Contains(lowerHostname, "appletv") || strings.Contains(lowerHostname, "apple-tv") {
					return "media"
				}
				return "computer"
				
			// Amazon devices
			case strings.Contains(lowerVendor, "amazon"):
				return "media"
				
			// Google devices
			case strings.Contains(lowerVendor, "google"):
				return "iot"
				
			// Network equipment vendors
			case strings.Contains(lowerVendor, "ubiquiti"),
				strings.Contains(lowerVendor, "cisco"),
				strings.Contains(lowerVendor, "netgear"):
				return "network"
			}
		}
	}
	
	return "unknown"
}

// getMacAddress gets MAC address for an IP from ARP table or arp-scan cache
func getMacAddress(ip string) string {
	// First try ARP table
	cmd := exec.Command("ip", "neigh", "show", ip)
	output, err := cmd.Output()
	if err == nil {
		// Parse output: "10.1.1.5 dev br-lan lladdr 00:e0:4c:bb:00:e3 REACHABLE"
		fields := strings.Fields(string(output))
		for i, field := range fields {
			if field == "lladdr" && i+1 < len(fields) {
				return fields[i+1]
			}
		}
	}
	
	// Fall back to arp-scan cache
	arpScanCacheLock.RLock()
	if entry, exists := arpScanCache[ip]; exists {
		mac := entry.MAC
		arpScanCacheLock.RUnlock()
		return mac
	}
	arpScanCacheLock.RUnlock()
	
	return ""
}

// getVendorForIP gets vendor information for an IP from arp-scan cache or OUI database
func getVendorForIP(ip string) string {
	arpScanCacheLock.RLock()
	if entry, exists := arpScanCache[ip]; exists && entry.Vendor != "" {
		vendor := entry.Vendor
		arpScanCacheLock.RUnlock()
		return vendor
	}
	arpScanCacheLock.RUnlock()
	
	// If no vendor from arp-scan, try OUI database with MAC address
	mac := getMacAddress(ip)
	if mac != "" {
		vendor := vendormap.MACVendor(mac)
		if vendor != "" {
			return vendor
		}
	}
	
	return ""
}

// loadClientDatabase loads client information from static clients file
func loadClientDatabase() map[string]ClientDBEntry {
	clientDB := make(map[string]ClientDBEntry)
	
	// Try to load static clients file
	staticClientsFile := os.Getenv("STATIC_CLIENTS_FILE")
	if staticClientsFile == "" {
		staticClientsFile = "/var/lib/network-metrics-exporter/static-clients.json"
	}
	
	data, err := os.ReadFile(staticClientsFile)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("Error reading static clients file: %v", err)
		}
		return clientDB
	}
	
	var staticClients map[string]struct {
		IP         string `json:"ip"`
		MAC        string `json:"mac"`
		Hostname   string `json:"hostname"`
		DeviceType string `json:"deviceType"`
	}
	
	if err := json.Unmarshal(data, &staticClients); err != nil {
		log.Printf("Error parsing static clients: %v", err)
		return clientDB
	}
	
	// Convert to ClientDBEntry format
	for _, client := range staticClients {
		if client.IP != "" {
			clientDB[client.IP] = ClientDBEntry{
				MAC:        client.MAC,
				Hostname:   client.Hostname,
				IP:         client.IP,
				DeviceType: client.DeviceType,
			}
		}
	}
	
	return clientDB
}

func updateWanIp() {
	if wanInterface == "" {
		// No WAN interface specified
		return
	}
	
	// Get IP address from the WAN interface
	cmd := exec.Command("ip", "addr", "show", wanInterface)
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Error getting WAN interface info: %v", err)
		return
	}
	
	// Parse the output to find IPv4 address
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "inet ") {
			// Format: inet 135.19.127.22/24 brd ...
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				ip := strings.Split(fields[1], "/")[0]
				// Update metric
				wanIpInfo.Reset()
				wanIpInfo.WithLabelValues(wanInterface, ip).Set(1)
				return
			}
		}
	}
	
	// No IP found
	wanIpInfo.Reset()
	wanIpInfo.WithLabelValues(wanInterface, "none").Set(0)
}

func updateClientDatabaseMetrics() {
	// Load client database
	clientDB := loadClientDatabase()
	
	// Count total clients
	total := 0
	online := 0
	deviceTypes := make(map[string]int)
	
	// Count static clients
	for _, entry := range clientDB {
		total++
		
		// Check if online based on ARP table
		cmd := exec.Command("ip", "neigh", "show", entry.IP)
		output, err := cmd.Output()
		if err == nil && strings.Contains(string(output), "REACHABLE") {
			online++
		}
		
		// Count by device type
		deviceType := entry.DeviceType
		if deviceType == "" {
			deviceType = "unknown"
		}
		deviceTypes[deviceType]++
	}
	
	// Also count dynamic clients from current session
	clientsLock.RLock()
	for ip, client := range clients {
		// Skip if already in database
		if _, exists := clientDB[ip]; exists {
			continue
		}
		
		total++
		
		// Check if seen recently (within last 5 minutes)
		if time.Since(client.LastSeen) < 5*time.Minute {
			online++
		}
		
		// Count by device type
		deviceType := client.DeviceType
		if deviceType == "" {
			deviceType = "unknown"
		}
		deviceTypes[deviceType]++
	}
	clientsLock.RUnlock()
	
	// Update metrics
	clientsTotal.Set(float64(total))
	clientsOnline.Set(float64(online))
	
	// Reset device type metrics
	clientsByType.Reset()
	for deviceType, count := range deviceTypes {
		clientsByType.WithLabelValues(deviceType).Set(float64(count))
	}
}

// runPeriodicArpScan runs ARP scans on a fixed schedule
func runPeriodicArpScan() {
	// Initial delay to avoid all discovery running at startup
	time.Sleep(30 * time.Second)
	
	// Run every 5 minutes
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	
	for {
		runArpScan()
		<-ticker.C
	}
}

// runPeriodicMDNSDiscovery runs mDNS discovery on a fixed schedule
func runPeriodicMDNSDiscovery() {
	// Initial delay to avoid all discovery running at startup
	time.Sleep(1 * time.Minute)
	
	// Run every 5 minutes
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	
	for {
		discoverMDNS()
		<-ticker.C
	}
}

// runArpScan performs an ARP scan of the local network and caches results
func runArpScan() {
	// Remove the time check since we're now called on a schedule
	// Only run if it's been more than 5 minutes since last scan
	// if time.Since(lastArpScan) < 5*time.Minute {
	//	return
	// }
	
	// Get network prefix from environment or use default
	networkPrefix := os.Getenv("NETWORK_PREFIX")
	if networkPrefix == "" {
		networkPrefix = "192.168.10"
	}
	
	// Get interface from environment or use default
	iface := os.Getenv("TRAFFIC_INTERFACE")
	if iface == "" {
		iface = "br-lan"
	}
	
	// Check if arp-scan is available
	if _, err := exec.LookPath("arp-scan"); err != nil {
		log.Printf("Warning: arp-scan not found in PATH, skipping ARP discovery: %v", err)
		return
	}
	
	// Run arp-scan on the local network
	cmd := exec.Command("arp-scan", "-l", "-I", iface, "--retry=2", "--timeout=200")
	output, err := cmd.Output()
	if err != nil {
		// Check if it's a permission error
		if exitErr, ok := err.(*exec.ExitError); ok {
			stderr := string(exitErr.Stderr)
			if strings.Contains(stderr, "permission denied") || strings.Contains(stderr, "Operation not permitted") {
				log.Printf("Error: arp-scan requires root privileges. Please run with appropriate capabilities or as root.")
			} else if strings.Contains(stderr, "Cannot find interface") {
				log.Printf("Error: Interface %s not found. Please check TRAFFIC_INTERFACE environment variable.", iface)
			} else {
				log.Printf("Error running arp-scan: %v\nStderr: %s", err, stderr)
			}
		} else {
			log.Printf("Error running arp-scan: %v", err)
		}
		return
	}
	
	// Parse arp-scan output
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	newCache := make(map[string]*ArpScanEntry)
	currentTime := time.Now()
	
	for scanner.Scan() {
		line := scanner.Text()
		// Skip comments and headers
		if strings.HasPrefix(line, "#") || strings.Contains(line, "Interface:") || line == "" {
			continue
		}
		
		// Parse lines in format: IP	MAC	Vendor
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasPrefix(fields[0], networkPrefix) {
			ip := fields[0]
			mac := fields[1]
			
			// Validate IP address
			if net.ParseIP(ip) == nil {
				continue
			}
			
			// Validate MAC address format (basic check)
			if !regexp.MustCompile(`^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$`).MatchString(mac) {
				continue
			}
			
			vendor := ""
			if len(fields) >= 3 {
				vendor = strings.Join(fields[2:], " ")
			}
			
			newCache[ip] = &ArpScanEntry{
				IP:       ip,
				MAC:      mac,
				Vendor:   vendor,
				LastSeen: currentTime,
			}
		}
	}
	
	// Update cache
	arpScanCacheLock.Lock()
	arpScanCache = newCache
	lastArpScan = currentTime
	arpScanCacheLock.Unlock()
	
	log.Printf("ARP scan completed: found %d devices", len(newCache))
}

// discoverMDNS performs mDNS discovery to find devices on the network
func discoverMDNS() {
	// Remove the time check since we're now called on a schedule
	// Only run if it's been more than 5 minutes since last scan
	// if time.Since(lastMDNSScan) < 5*time.Minute {
	//	return
	// }
	
	// Check if we can bind to mDNS port (5353)
	// This is a quick check to see if mDNS is likely to work
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		log.Printf("Warning: Cannot create UDP socket for mDNS, skipping discovery: %v", err)
		return
	}
	conn.Close()
	
	log.Println("Starting mDNS discovery...")
	
	// Get network prefix from environment or use default
	networkPrefix := os.Getenv("NETWORK_PREFIX")
	if networkPrefix == "" {
		networkPrefix = "192.168.10"
	}
	
	// Common service types to browse
	serviceTypes := []string{
		"_http._tcp",
		"_airplay._tcp",
		"_googlecast._tcp",
		"_spotify-connect._tcp",
		"_printer._tcp",
		"_ipp._tcp",
		"_pdl-datastream._tcp",
		"_raop._tcp",
		"_homekit._tcp",
		"_companion-link._tcp",
		"_workstation._tcp",
		"_ssh._tcp",
		"_device-info._tcp",
		"_apple-mobdev2._tcp",
		"_daap._tcp",
		"_home-sharing._tcp",
	}
	
	newCache := make(map[string]*MDNSEntry)
	currentTime := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	
	var wg sync.WaitGroup
	cacheMutex := sync.Mutex{}
	successCount := 0
	errorCount := 0
	
	// Limit concurrent mDNS queries to reduce CPU usage
	semaphore := make(chan struct{}, 3) // Max 3 concurrent queries
	
	// Browse each service type
	for _, serviceType := range serviceTypes {
		wg.Add(1)
		go func(service string) {
			defer wg.Done()
			
			// Acquire semaphore
			semaphore <- struct{}{}
			defer func() { <-semaphore }()
			defer func() {
				if r := recover(); r != nil {
					log.Printf("Panic in mDNS discovery for %s: %v", service, r)
					errorCount++
				}
			}()
			
			resolver, err := zeroconf.NewResolver(nil)
			if err != nil {
				log.Printf("Failed to create resolver for %s: %v", service, err)
				errorCount++
				return
			}
			
			entries := make(chan *zeroconf.ServiceEntry)
			go func() {
				for entry := range entries {
					// Check if IP is in our network
					for _, ip := range entry.AddrIPv4 {
						if strings.HasPrefix(ip.String(), networkPrefix) {
							deviceType := inferDeviceTypeFromService(service, entry.Instance)
							
							cacheMutex.Lock()
							key := ip.String()
							if existing, exists := newCache[key]; exists {
								// Update with more specific info if available
								if existing.DeviceType == "unknown" && deviceType != "unknown" {
									existing.DeviceType = deviceType
								}
								if existing.Service == "" {
									existing.Service = service
								}
							} else {
								newCache[key] = &MDNSEntry{
									IP:         ip.String(),
									Hostname:   entry.HostName,
									Instance:   entry.Instance,
									Service:    service,
									Domain:     entry.Domain,
									DeviceType: deviceType,
									LastSeen:   currentTime,
								}
							}
							cacheMutex.Unlock()
						}
					}
				}
			}()
			
			if err := resolver.Browse(ctx, service, "local.", entries); err != nil {
				log.Printf("Failed to browse %s: %v", service, err)
				errorCount++
			} else {
				successCount++
			}
		}(serviceType)
	}
	
	wg.Wait()
	
	// Update cache only if we had some success
	if successCount > 0 || len(newCache) > 0 {
		mdnsCacheLock.Lock()
		mdnsCache = newCache
		lastMDNSScan = currentTime
		mdnsCacheLock.Unlock()
		
		log.Printf("mDNS discovery completed: found %d devices, %d services succeeded, %d failed", 
			len(newCache), successCount, errorCount)
	} else if errorCount > 0 {
		log.Printf("mDNS discovery failed: all %d service lookups failed", errorCount)
	}
}

// inferDeviceTypeFromService infers device type from mDNS service type
// backgroundDNSResolver processes DNS lookups in the background to avoid blocking
func backgroundDNSResolver() {
	for ip := range dnsResolveQueue {
		// Check if we already have it cached
		dnsResolveCacheLock.RLock()
		if _, exists := dnsResolveCache[ip]; exists {
			dnsResolveCacheLock.RUnlock()
			continue
		}
		dnsResolveCacheLock.RUnlock()
		
		// Perform DNS lookup with timeout
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		resolver := &net.Resolver{}
		names, err := resolver.LookupAddr(ctx, ip)
		cancel()
		
		var resolvedName string
		if err == nil && len(names) > 0 {
			// Use the first name, remove trailing dot and .lan suffix
			name := strings.TrimSuffix(names[0], ".")
			name = strings.TrimSuffix(name, ".lan")
			
			// If it's just an IP-based name, ignore it
			if !strings.Contains(name, ip) {
				resolvedName = name
			}
		}
		
		// Cache the result (even if empty to avoid repeated lookups)
		dnsResolveCacheLock.Lock()
		dnsResolveCache[ip] = resolvedName
		dnsResolveCacheLock.Unlock()
		
		// If we got a name, update the main cache too
		if resolvedName != "" {
			updateClientNameCache(ip, resolvedName)
		}
	}
}

func inferDeviceTypeFromService(service string, instance string) string {
	lowerService := strings.ToLower(service)
	lowerInstance := strings.ToLower(instance)
	
	switch {
	// Media devices
	case strings.Contains(lowerService, "_airplay"), 
		strings.Contains(lowerService, "_googlecast"),
		strings.Contains(lowerService, "_spotify-connect"),
		strings.Contains(lowerService, "_raop"),
		strings.Contains(lowerService, "_daap"):
		return "media"
		
	// Printers
	case strings.Contains(lowerService, "_printer"),
		strings.Contains(lowerService, "_ipp"),
		strings.Contains(lowerService, "_pdl-datastream"):
		return "printer"
		
	// IoT/Smart home
	case strings.Contains(lowerService, "_homekit"):
		return "iot"
		
	// Computers/Workstations
	case strings.Contains(lowerService, "_workstation"),
		strings.Contains(lowerService, "_ssh"):
		return "computer"
		
	// Apple mobile devices
	case strings.Contains(lowerService, "_apple-mobdev"),
		strings.Contains(lowerService, "_companion-link"):
		if strings.Contains(lowerInstance, "iphone") {
			return "phone"
		} else if strings.Contains(lowerInstance, "ipad") {
			return "tablet"
		}
		return "phone" // Default to phone for Apple mobile devices
	}
	
	return "unknown"
}
