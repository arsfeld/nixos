package services

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
)

// Client represents a network client
type Client struct {
	MAC          string    `json:"mac"`
	IP           string    `json:"ip"`
	Hostname     string    `json:"hostname"`
	Name         string    `json:"name"`
	DeviceType   string    `json:"device_type"`
	Manufacturer string    `json:"manufacturer"`
	OS           string    `json:"os"`
	Notes        string    `json:"notes"`
	Tags         []string  `json:"tags"`
	FirstSeen    time.Time `json:"first_seen"`
	LastSeen     time.Time `json:"last_seen"`
	Static       bool      `json:"static"`
	Online       bool      `json:"online"`
}

// ClientDiscoveryService handles network client discovery
type ClientDiscoveryService struct {
	db              *db.DB
	ctx             context.Context
	cancel          context.CancelFunc
	wg              sync.WaitGroup
	mu              sync.RWMutex
	clients         map[string]*Client
	ouiDB           *OUIDatabase
	scanInterval    time.Duration
	clientListeners []chan ClientUpdate
}

// ClientUpdate represents a client state change
type ClientUpdate struct {
	Client *Client
	Event  string // "new", "updated", "offline", "online"
}

// NewClientDiscoveryService creates a new client discovery service
func NewClientDiscoveryService(database *db.DB) *ClientDiscoveryService {
	ctx, cancel := context.WithCancel(context.Background())
	
	return &ClientDiscoveryService{
		db:           database,
		ctx:          ctx,
		cancel:       cancel,
		clients:      make(map[string]*Client),
		scanInterval: 30 * time.Second,
		ouiDB:        NewOUIDatabase(),
	}
}

// Start begins the discovery process
func (s *ClientDiscoveryService) Start() error {
	log.Println("Starting client discovery service...")
	
	// Load existing clients from database
	if err := s.loadClients(); err != nil {
		return fmt.Errorf("failed to load clients: %w", err)
	}
	
	// Start discovery goroutines
	s.wg.Add(3)
	go s.arpScanner()
	go s.dhcpMonitor()
	go s.clientHealthChecker()
	
	return nil
}

// Stop gracefully shuts down the service
func (s *ClientDiscoveryService) Stop() error {
	log.Println("Stopping client discovery service...")
	s.cancel()
	s.wg.Wait()
	return nil
}

// GetClients returns all known clients
func (s *ClientDiscoveryService) GetClients() []*Client {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	clients := make([]*Client, 0, len(s.clients))
	for _, client := range s.clients {
		clients = append(clients, client)
	}
	return clients
}

// GetClient returns a specific client by MAC
func (s *ClientDiscoveryService) GetClient(mac string) (*Client, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	client, exists := s.clients[strings.ToLower(mac)]
	return client, exists
}

// UpdateClient updates client information
func (s *ClientDiscoveryService) UpdateClient(mac string, updates map[string]interface{}) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	mac = strings.ToLower(mac)
	client, exists := s.clients[mac]
	if !exists {
		return fmt.Errorf("client not found: %s", mac)
	}
	
	// Apply updates
	if name, ok := updates["name"].(string); ok {
		client.Name = name
	}
	if deviceType, ok := updates["device_type"].(string); ok {
		client.DeviceType = deviceType
	}
	if notes, ok := updates["notes"].(string); ok {
		client.Notes = notes
	}
	if tags, ok := updates["tags"].([]string); ok {
		client.Tags = tags
	}
	
	// Save to database
	return s.saveClient(client)
}

// Subscribe returns a channel for client updates
func (s *ClientDiscoveryService) Subscribe() <-chan ClientUpdate {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	ch := make(chan ClientUpdate, 100)
	s.clientListeners = append(s.clientListeners, ch)
	return ch
}

// Private methods

func (s *ClientDiscoveryService) loadClients() error {
	keys, err := s.db.List("client:")
	if err != nil {
		return err
	}
	
	s.mu.Lock()
	defer s.mu.Unlock()
	
	for _, key := range keys {
		var client Client
		if err := s.db.GetJSON(key, &client); err != nil {
			log.Printf("Failed to load client from %s: %v", key, err)
			continue
		}
		s.clients[strings.ToLower(client.MAC)] = &client
	}
	
	log.Printf("Loaded %d clients from database", len(s.clients))
	return nil
}

func (s *ClientDiscoveryService) saveClient(client *Client) error {
	key := fmt.Sprintf("client:%s", strings.ToLower(client.MAC))
	return s.db.SetJSON(key, client)
}

func (s *ClientDiscoveryService) arpScanner() {
	defer s.wg.Done()
	
	ticker := time.NewTicker(s.scanInterval)
	defer ticker.Stop()
	
	// Initial scan
	s.scanARP()
	
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.scanARP()
		}
	}
}

func (s *ClientDiscoveryService) scanARP() {
	// Use ip neigh to get ARP/neighbor table
	cmd := exec.Command("ip", "neigh", "show")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Failed to get ARP table: %v", err)
		return
	}
	
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	arpEntries := make(map[string]string) // MAC -> IP
	
	// Parse ARP entries
	// Format: 192.168.1.100 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
	arpRegex := regexp.MustCompile(`^(\S+)\s+dev\s+\S+\s+lladdr\s+([0-9a-fA-F:]+)\s+(\S+)`)
	
	for scanner.Scan() {
		line := scanner.Text()
		matches := arpRegex.FindStringSubmatch(line)
		if len(matches) >= 3 {
			ip := matches[1]
			mac := strings.ToLower(matches[2])
			state := matches[3]
			
			// Only track reachable/valid entries
			if state == "REACHABLE" || state == "STALE" || state == "PERMANENT" {
				arpEntries[mac] = ip
			}
		}
	}
	
	// Update client database
	s.mu.Lock()
	defer s.mu.Unlock()
	
	now := time.Now()
	
	// Process discovered entries
	for mac, ip := range arpEntries {
		client, exists := s.clients[mac]
		if !exists {
			// New client discovered
			client = &Client{
				MAC:       mac,
				IP:        ip,
				FirstSeen: now,
				LastSeen:  now,
				Online:    true,
			}
			
			// Lookup manufacturer from OUI database
			if s.ouiDB != nil {
				client.Manufacturer = s.ouiDB.Lookup(mac)
			}
			
			// Try to resolve hostname
			if hostname := s.resolveHostname(ip); hostname != "" {
				client.Hostname = hostname
			}
			
			// Guess device type based on MAC/manufacturer
			client.DeviceType = s.guessDeviceType(client)
			
			s.clients[mac] = client
			s.saveClient(client)
			s.notifyListeners(ClientUpdate{Client: client, Event: "new"})
			
			log.Printf("New client discovered: %s (%s) - %s", mac, ip, client.Manufacturer)
		} else {
			// Update existing client
			updated := false
			
			if client.IP != ip {
				client.IP = ip
				updated = true
			}
			
			if !client.Online {
				client.Online = true
				updated = true
				s.notifyListeners(ClientUpdate{Client: client, Event: "online"})
			}
			
			client.LastSeen = now
			
			if updated {
				s.saveClient(client)
			}
		}
	}
}

func (s *ClientDiscoveryService) dhcpMonitor() {
	defer s.wg.Done()
	
	// Monitor DHCP lease files
	keaLeaseFile := "/var/lib/kea/kea-leases4.csv"
	dnsmasqLeaseFile := "/var/lib/dnsmasq/dnsmasq.leases"
	
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			// Check Kea DHCP
			if _, err := os.Stat(keaLeaseFile); err == nil {
				s.parseKeaLeases(keaLeaseFile)
			}
			
			// Check dnsmasq
			if _, err := os.Stat(dnsmasqLeaseFile); err == nil {
				s.parseDnsmasqLeases(dnsmasqLeaseFile)
			}
		}
	}
}

func (s *ClientDiscoveryService) parseKeaLeases(filename string) {
	file, err := os.Open(filename)
	if err != nil {
		return
	}
	defer file.Close()
	
	scanner := bufio.NewScanner(file)
	scanner.Scan() // Skip header
	
	s.mu.Lock()
	defer s.mu.Unlock()
	
	for scanner.Scan() {
		// Format: address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state
		fields := strings.Split(scanner.Text(), ",")
		if len(fields) >= 9 {
			ip := fields[0]
			mac := strings.ToLower(fields[1])
			hostname := fields[8]
			
			if client, exists := s.clients[mac]; exists {
				if hostname != "" && client.Hostname != hostname {
					client.Hostname = hostname
					s.saveClient(client)
				}
			}
		}
	}
}

func (s *ClientDiscoveryService) parseDnsmasqLeases(filename string) {
	file, err := os.Open(filename)
	if err != nil {
		return
	}
	defer file.Close()
	
	scanner := bufio.NewScanner(file)
	
	s.mu.Lock()
	defer s.mu.Unlock()
	
	for scanner.Scan() {
		// Format: expire_time mac_address ip_address hostname client_id
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 4 {
			mac := strings.ToLower(fields[1])
			ip := fields[2]
			hostname := fields[3]
			
			if hostname != "*" {
				if client, exists := s.clients[mac]; exists {
					if client.Hostname != hostname {
						client.Hostname = hostname
						s.saveClient(client)
					}
				}
			}
		}
	}
}

func (s *ClientDiscoveryService) clientHealthChecker() {
	defer s.wg.Done()
	
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()
	
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.checkClientHealth()
		}
	}
}

func (s *ClientDiscoveryService) checkClientHealth() {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	now := time.Now()
	offlineThreshold := 5 * time.Minute
	
	for _, client := range s.clients {
		if client.Online && now.Sub(client.LastSeen) > offlineThreshold {
			client.Online = false
			s.saveClient(client)
			s.notifyListeners(ClientUpdate{Client: client, Event: "offline"})
			log.Printf("Client went offline: %s (%s)", client.MAC, client.Hostname)
		}
	}
}

func (s *ClientDiscoveryService) resolveHostname(ip string) string {
	names, err := net.LookupAddr(ip)
	if err != nil || len(names) == 0 {
		return ""
	}
	
	// Remove trailing dot
	hostname := strings.TrimSuffix(names[0], ".")
	return hostname
}

func (s *ClientDiscoveryService) guessDeviceType(client *Client) string {
	manufacturer := strings.ToLower(client.Manufacturer)
	hostname := strings.ToLower(client.Hostname)
	
	// Phone manufacturers
	if strings.Contains(manufacturer, "apple") && 
		(strings.Contains(hostname, "iphone") || strings.Contains(hostname, "ipad")) {
		if strings.Contains(hostname, "ipad") {
			return "tablet"
		}
		return "phone"
	}
	
	if strings.Contains(manufacturer, "samsung") || 
		strings.Contains(manufacturer, "huawei") ||
		strings.Contains(manufacturer, "xiaomi") ||
		strings.Contains(manufacturer, "oneplus") {
		return "phone"
	}
	
	// Computers
	if strings.Contains(manufacturer, "dell") ||
		strings.Contains(manufacturer, "hewlett") ||
		strings.Contains(manufacturer, "lenovo") ||
		strings.Contains(manufacturer, "asus") {
		return "computer"
	}
	
	// IoT devices
	if strings.Contains(manufacturer, "espressif") ||
		strings.Contains(manufacturer, "tuya") ||
		strings.Contains(manufacturer, "sonoff") {
		return "iot"
	}
	
	// TV/Media devices
	if strings.Contains(manufacturer, "roku") ||
		strings.Contains(manufacturer, "amazon") ||
		strings.Contains(hostname, "chromecast") ||
		strings.Contains(hostname, "appletv") {
		return "tv"
	}
	
	// Printers
	if strings.Contains(manufacturer, "canon") ||
		strings.Contains(manufacturer, "epson") ||
		strings.Contains(manufacturer, "brother") ||
		strings.Contains(hostname, "printer") {
		return "printer"
	}
	
	return "unknown"
}

func (s *ClientDiscoveryService) notifyListeners(update ClientUpdate) {
	for _, ch := range s.clientListeners {
		select {
		case ch <- update:
		default:
			// Channel full, skip
		}
	}
}

// OUIDatabase handles MAC address manufacturer lookups
type OUIDatabase struct {
	entries map[string]string
}

// NewOUIDatabase creates a new OUI database
func NewOUIDatabase() *OUIDatabase {
	db := &OUIDatabase{
		entries: make(map[string]string),
	}
	
	// Load some common entries (in production, load from file)
	db.entries["00:1b:63"] = "Apple Inc."
	db.entries["00:1e:c2"] = "Apple Inc."
	db.entries["00:25:00"] = "Apple Inc."
	db.entries["00:26:08"] = "Apple Inc."
	db.entries["00:1c:b3"] = "Apple Inc."
	db.entries["ac:87:a3"] = "Apple Inc."
	db.entries["00:9a:cd"] = "Huawei Technologies"
	db.entries["00:18:82"] = "Huawei Technologies"
	db.entries["00:0c:29"] = "VMware Inc."
	db.entries["00:50:56"] = "VMware Inc."
	db.entries["00:16:3e"] = "Xensource Inc."
	db.entries["52:54:00"] = "QEMU/KVM"
	db.entries["00:15:5d"] = "Microsoft Hyper-V"
	
	return db
}

// Lookup returns the manufacturer for a MAC address
func (o *OUIDatabase) Lookup(mac string) string {
	// Get first 3 octets
	parts := strings.Split(mac, ":")
	if len(parts) < 3 {
		return ""
	}
	
	prefix := strings.ToLower(strings.Join(parts[:3], ":"))
	if manufacturer, exists := o.entries[prefix]; exists {
		return manufacturer
	}
	
	return "Unknown"
}