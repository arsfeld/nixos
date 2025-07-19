package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Config struct {
	ListenInterface   string
	ListenPort        int
	ExternalInterface string
	
	NatTable    string
	NatChain    string
	FilterTable string
	FilterChain string
	
	AllowedPorts     []PortRange
	MaxMappingsPerIP int
	DefaultLifetime  int
	MaxLifetime      int
	
	StateDir        string
	LogLevel        string
	CleanupInterval int
	MetricsPort     int
	Verbose         bool
}

type PortRange struct {
	Start uint16
	End   uint16
}

type Mapping struct {
	InternalIP   string    `json:"internal_ip"`
	InternalPort uint16    `json:"internal_port"`
	ExternalPort uint16    `json:"external_port"`
	Protocol     string    `json:"protocol"`
	Lifetime     uint32    `json:"lifetime"`
	CreatedAt    time.Time `json:"created_at"`
	ExpiresAt    time.Time `json:"expires_at"`
	RuleHandle   uint64    `json:"rule_handle,omitempty"`
}

type StateManager struct {
	mu       sync.RWMutex
	mappings []Mapping
	stateDir string
}

type NFTablesManager struct {
	config *Config
}

type NATPMPServer struct {
	config       *Config
	stateManager *StateManager
	nftManager   *NFTablesManager
	conn         *net.UDPConn
}

const (
	NATPMP_VERSION   = 0
	NATPMP_PORT      = 5351
	OPCODE_INFO      = 0
	OPCODE_MAP_UDP   = 1
	OPCODE_MAP_TCP   = 2
	RESPONSE_SUCCESS = 0
	RESPONSE_VERSION = 1
	RESPONSE_REFUSED = 2
	RESPONSE_NETWORK = 3
	RESPONSE_RSRC    = 4
	RESPONSE_OPCODE  = 5
)

var globalConfig *Config

func logVerbose(format string, v ...interface{}) {
	if globalConfig != nil && globalConfig.Verbose {
		log.Printf(format, v...)
	}
}

func main() {
	config := parseConfig()
	globalConfig = config
	
	stateManager := NewStateManager(config.StateDir)
	if err := stateManager.LoadState(); err != nil {
		log.Printf("Failed to load state: %v", err)
	}
	
	nftManager := NewNFTablesManager(config)
	
	if err := nftManager.EnsureTablesAndChains(); err != nil {
		log.Fatalf("Failed to setup nftables: %v", err)
	}
	
	mappings := stateManager.GetMappings()
	for i := range mappings {
		if err := nftManager.AddMapping(&mappings[i]); err != nil {
			log.Printf("Failed to restore mapping: %v", err)
		}
	}
	
	go cleanupExpiredMappings(stateManager, nftManager, config.CleanupInterval)
	
	// Start metrics HTTP server
	if config.MetricsPort > 0 {
		go func() {
			http.Handle("/metrics", promhttp.Handler())
			addr := fmt.Sprintf(":%d", config.MetricsPort)
			log.Printf("Starting metrics server on %s", addr)
			if err := http.ListenAndServe(addr, nil); err != nil {
				log.Printf("Failed to start metrics server: %v", err)
			}
		}()
	}
	
	// Update initial metrics
	updateActiveMappingsMetrics(stateManager.GetMappings())
	updatePortRangeUsage(stateManager.GetMappings(), config.AllowedPorts)
	
	server := NewNATPMPServer(config, stateManager, nftManager)
	
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	
	go func() {
		<-sigChan
		log.Println("Shutting down...")
		server.Shutdown()
		os.Exit(0)
	}()
	
	log.Fatal(server.ListenAndServe())
}

func parseConfig() *Config {
	config := &Config{
		AllowedPorts: []PortRange{{Start: 1024, End: 65535}},
	}
	
	flag.StringVar(&config.ListenInterface, "listen-interface", "br-lan", "Interface to listen on")
	flag.IntVar(&config.ListenPort, "listen-port", NATPMP_PORT, "Port to listen on")
	flag.StringVar(&config.ExternalInterface, "external-interface", "eth0", "External interface")
	
	flag.StringVar(&config.NatTable, "nat-table", "nat", "nftables NAT table name")
	flag.StringVar(&config.NatChain, "nat-chain", "NATPMP", "nftables NAT chain name")
	flag.StringVar(&config.FilterTable, "filter-table", "filter", "nftables filter table name")
	flag.StringVar(&config.FilterChain, "filter-chain", "NATPMP", "nftables filter chain name")
	
	flag.IntVar(&config.MaxMappingsPerIP, "max-mappings-per-ip", 100, "Maximum mappings per IP")
	flag.IntVar(&config.DefaultLifetime, "default-lifetime", 3600, "Default mapping lifetime (seconds)")
	flag.IntVar(&config.MaxLifetime, "max-lifetime", 86400, "Maximum mapping lifetime (seconds)")
	
	flag.StringVar(&config.StateDir, "state-dir", "/var/lib/natpmp-server", "State directory")
	flag.StringVar(&config.LogLevel, "log-level", "info", "Log level")
	flag.IntVar(&config.CleanupInterval, "cleanup-interval", 60, "Cleanup interval (seconds)")
	flag.IntVar(&config.MetricsPort, "metrics-port", 9100, "Port for Prometheus metrics endpoint")
	flag.BoolVar(&config.Verbose, "verbose", false, "Enable verbose logging")
	
	flag.Parse()
	
	return config
}

func NewStateManager(stateDir string) *StateManager {
	return &StateManager{
		stateDir: stateDir,
		mappings: make([]Mapping, 0),
	}
}

func (sm *StateManager) LoadState() error {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	
	statePath := filepath.Join(sm.stateDir, "mappings.json")
	data, err := os.ReadFile(statePath)
	if err != nil {
		if os.IsNotExist(err) {
			stateOperations.WithLabelValues("load", "success").Inc()
			return nil
		}
		stateOperations.WithLabelValues("load", "error").Inc()
		return err
	}
	
	var state struct {
		Mappings []Mapping `json:"mappings"`
	}
	
	if err := json.Unmarshal(data, &state); err != nil {
		return err
	}
	
	now := time.Now()
	for _, m := range state.Mappings {
		if m.ExpiresAt.After(now) {
			sm.mappings = append(sm.mappings, m)
		}
	}
	
	stateOperations.WithLabelValues("load", "success").Inc()
	return nil
}

// saveStateInternal saves state without acquiring locks
// Must be called while holding at least a read lock
func (sm *StateManager) saveStateInternal() error {
	logVerbose("Saving state with %d mappings", len(sm.mappings))
	
	state := struct {
		Mappings []Mapping `json:"mappings"`
	}{
		Mappings: sm.mappings,
	}
	
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		stateOperations.WithLabelValues("save", "error").Inc()
		return err
	}
	
	statePath := filepath.Join(sm.stateDir, "mappings.json")
	tempPath := statePath + ".tmp"
	
	if err := os.MkdirAll(sm.stateDir, 0755); err != nil {
		stateOperations.WithLabelValues("save", "error").Inc()
		return err
	}
	
	if err := os.WriteFile(tempPath, data, 0644); err != nil {
		stateOperations.WithLabelValues("save", "error").Inc()
		return fmt.Errorf("failed to write temp state file: %w", err)
	}
	
	if err := os.Rename(tempPath, statePath); err != nil {
		stateOperations.WithLabelValues("save", "error").Inc()
		return err
	}
	
	stateOperations.WithLabelValues("save", "success").Inc()
	logVerbose("State saved successfully to %s", statePath)
	return nil
}

func (sm *StateManager) SaveState() error {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	return sm.saveStateInternal()
}

func (sm *StateManager) AddMapping(m Mapping) error {
	sm.mu.Lock()
	
	sm.mappings = append(sm.mappings, m)
	mappingsCreatedTotal.WithLabelValues(m.Protocol).Inc()
	
	// Create a copy of mappings for metrics update
	mappingsCopy := make([]Mapping, len(sm.mappings))
	copy(mappingsCopy, sm.mappings)
	
	// Save state before releasing lock
	err := sm.saveStateInternal()
	sm.mu.Unlock()
	
	// Update metrics after releasing the lock
	go func() {
		updateActiveMappingsMetrics(mappingsCopy)
	}()
	
	return err
}

func (sm *StateManager) RemoveExpiredMappings() []Mapping {
	sm.mu.Lock()
	
	now := time.Now()
	expired := make([]Mapping, 0)
	active := make([]Mapping, 0)
	
	for _, m := range sm.mappings {
		if m.ExpiresAt.Before(now) {
			expired = append(expired, m)
			mappingsExpiredTotal.WithLabelValues(m.Protocol).Inc()
			mappingsDeletedTotal.WithLabelValues(m.Protocol, "expired").Inc()
		} else {
			active = append(active, m)
		}
	}
	
	sm.mappings = active
	sm.saveStateInternal()
	
	// Create a copy of active mappings for metrics update
	mappingsCopy := make([]Mapping, len(sm.mappings))
	copy(mappingsCopy, sm.mappings)
	
	sm.mu.Unlock()
	
	// Update metrics after releasing the lock
	go func() {
		updateActiveMappingsMetrics(mappingsCopy)
	}()
	
	return expired
}

func (sm *StateManager) CountMappingsForIP(ip string) int {
	logVerbose("CountMappingsForIP: acquiring read lock for IP %s", ip)
	sm.mu.RLock()
	logVerbose("CountMappingsForIP: acquired read lock for IP %s", ip)
	defer func() {
		sm.mu.RUnlock()
		logVerbose("CountMappingsForIP: released read lock for IP %s", ip)
	}()
	
	count := 0
	logVerbose("CountMappingsForIP: checking %d mappings", len(sm.mappings))
	for _, m := range sm.mappings {
		if m.InternalIP == ip {
			count++
		}
	}
	logVerbose("CountMappingsForIP: found %d mappings for IP %s", count, ip)
	return count
}

func (sm *StateManager) GetMappings() []Mapping {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	mappings := make([]Mapping, len(sm.mappings))
	copy(mappings, sm.mappings)
	return mappings
}

// FindExistingMapping checks if a mapping already exists for the given parameters
func (sm *StateManager) FindExistingMapping(internalIP string, internalPort uint16, externalPort uint16, protocol string) (*Mapping, int) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	
	for i, m := range sm.mappings {
		if m.InternalIP == internalIP && 
		   m.InternalPort == internalPort && 
		   m.ExternalPort == externalPort && 
		   m.Protocol == protocol {
			mapping := m
			return &mapping, i
		}
	}
	return nil, -1
}

// UpdateMapping updates an existing mapping's lifetime
func (sm *StateManager) UpdateMapping(index int, lifetime uint32) error {
	sm.mu.Lock()
	
	if index < 0 || index >= len(sm.mappings) {
		sm.mu.Unlock()
		return fmt.Errorf("invalid mapping index")
	}
	
	sm.mappings[index].Lifetime = lifetime
	sm.mappings[index].ExpiresAt = time.Now().Add(time.Duration(lifetime) * time.Second)
	
	// Create a copy for metrics update
	mappingsCopy := make([]Mapping, len(sm.mappings))
	copy(mappingsCopy, sm.mappings)
	
	err := sm.saveStateInternal()
	sm.mu.Unlock()
	
	// Update metrics after releasing the lock
	go func() {
		updateActiveMappingsMetrics(mappingsCopy)
	}()
	
	return err
}

// RemoveMapping removes a specific mapping by index
func (sm *StateManager) RemoveMapping(index int) (*Mapping, error) {
	sm.mu.Lock()
	
	if index < 0 || index >= len(sm.mappings) {
		sm.mu.Unlock()
		return nil, fmt.Errorf("invalid mapping index")
	}
	
	// Get the mapping to return
	mapping := sm.mappings[index]
	
	// Remove the mapping from the slice
	sm.mappings = append(sm.mappings[:index], sm.mappings[index+1:]...)
	
	// Update metrics
	mappingsDeletedTotal.WithLabelValues(mapping.Protocol, "deleted").Inc()
	
	// Create a copy for metrics update
	mappingsCopy := make([]Mapping, len(sm.mappings))
	copy(mappingsCopy, sm.mappings)
	
	err := sm.saveStateInternal()
	sm.mu.Unlock()
	
	// Update metrics after releasing the lock
	go func() {
		updateActiveMappingsMetrics(mappingsCopy)
	}()
	
	return &mapping, err
}

func NewNFTablesManager(config *Config) *NFTablesManager {
	return &NFTablesManager{config: config}
}

func NewNATPMPServer(config *Config, stateManager *StateManager, nftManager *NFTablesManager) *NATPMPServer {
	return &NATPMPServer{
		config:       config,
		stateManager: stateManager,
		nftManager:   nftManager,
	}
}

func (s *NATPMPServer) ListenAndServe() error {
	addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf(":%d", s.config.ListenPort))
	if err != nil {
		return err
	}
	
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	
	s.conn = conn
	defer conn.Close()
	
	log.Printf("NAT-PMP server listening on %s", addr)
	
	buf := make([]byte, 1024)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			// Check if this is a shutdown-related error
			if netErr, ok := err.(*net.OpError); ok && netErr.Err.Error() == "use of closed network connection" {
				// This is expected during shutdown, exit gracefully
				return nil
			}
			log.Printf("Read error: %v", err)
			continue
		}
		
		logVerbose("Received UDP packet: %d bytes from %s", n, clientAddr)
		// Make a copy of the data for the goroutine
		data := make([]byte, n)
		copy(data, buf[:n])
		go s.handleRequest(data, clientAddr)
	}
}

func (s *NATPMPServer) handleRequest(data []byte, addr *net.UDPAddr) {
	logVerbose("handleRequest goroutine started for %s", addr)
	defer logVerbose("handleRequest goroutine finished for %s", addr)
	
	logVerbose("Received %d bytes from %s", len(data), addr)
	
	if len(data) < 2 {
		logVerbose("Request too short: %d bytes", len(data))
		return
	}
	
	version := data[0]
	opcode := data[1]
	
	logVerbose("Request: version=%d, opcode=%d", version, opcode)
	
	if version != NATPMP_VERSION {
		logVerbose("Invalid version %d from %s", version, addr)
		requestsTotal.WithLabelValues("unknown", "error_version").Inc()
		s.sendErrorResponse(addr, opcode, RESPONSE_VERSION)
		return
	}
	
	var requestType string
	switch opcode {
	case OPCODE_INFO:
		requestType = "info"
		timer := prometheus.NewTimer(requestDuration.WithLabelValues(requestType))
		defer timer.ObserveDuration()
		s.handleInfoRequest(addr)
	case OPCODE_MAP_UDP:
		requestType = "map_udp"
		timer := prometheus.NewTimer(requestDuration.WithLabelValues(requestType))
		defer timer.ObserveDuration()
		s.handleMappingRequest(data, addr, opcode)
	case OPCODE_MAP_TCP:
		requestType = "map_tcp"
		timer := prometheus.NewTimer(requestDuration.WithLabelValues(requestType))
		defer timer.ObserveDuration()
		s.handleMappingRequest(data, addr, opcode)
	default:
		requestsTotal.WithLabelValues("unknown", "error_opcode").Inc()
		s.sendErrorResponse(addr, opcode, RESPONSE_OPCODE)
	}
}

func (s *NATPMPServer) handleInfoRequest(addr *net.UDPAddr) {
	externalIP := s.getExternalIP()
	
	response := make([]byte, 12)
	response[0] = NATPMP_VERSION
	response[1] = OPCODE_INFO + 128
	response[2] = 0
	response[3] = RESPONSE_SUCCESS
	
	epoch := uint32(time.Now().Unix())
	response[4] = byte(epoch >> 24)
	response[5] = byte(epoch >> 16)
	response[6] = byte(epoch >> 8)
	response[7] = byte(epoch)
	
	copy(response[8:12], externalIP.To4())
	
	s.conn.WriteToUDP(response, addr)
	requestsTotal.WithLabelValues("info", "success").Inc()
}

func (s *NATPMPServer) handleMappingRequest(data []byte, addr *net.UDPAddr, opcode byte) {
	logVerbose("Handling mapping request from %s, opcode=%d", addr, opcode)
	
	if len(data) < 12 {
		logVerbose("Mapping request too short: %d bytes", len(data))
		s.sendErrorResponse(addr, opcode, RESPONSE_NETWORK)
		return
	}
	
	internalPort := uint16(data[4])<<8 | uint16(data[5])
	externalPort := uint16(data[6])<<8 | uint16(data[7])
	lifetime := uint32(data[8])<<24 | uint32(data[9])<<16 | uint32(data[10])<<8 | uint32(data[11])
	
	protocol := "udp"
	if opcode == OPCODE_MAP_TCP {
		protocol = "tcp"
	}
	
	logVerbose("Mapping request: internal=%d, external=%d, lifetime=%d, protocol=%s",
		internalPort, externalPort, lifetime, protocol)
	
	if lifetime > uint32(s.config.MaxLifetime) {
		lifetime = uint32(s.config.MaxLifetime)
	}
	
	logVerbose("Checking mapping count for IP %s", addr.IP.String())
	mappingCount := s.stateManager.CountMappingsForIP(addr.IP.String())
	logVerbose("IP %s has %d mappings (max %d)", addr.IP.String(), mappingCount, s.config.MaxMappingsPerIP)
	
	if mappingCount >= s.config.MaxMappingsPerIP {
		logVerbose("IP %s exceeded max mappings limit", addr.IP.String())
		requestsTotal.WithLabelValues(protocol, "error_limit").Inc()
		s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
		return
	}
	
	if externalPort == 0 {
		externalPort = internalPort
		logVerbose("External port was 0, using internal port %d", externalPort)
	}
	
	if !s.isPortAllowed(externalPort) {
		logVerbose("Port %d not allowed (outside allowed range)", externalPort)
		requestsTotal.WithLabelValues(protocol, "error_refused").Inc()
		s.sendErrorResponse(addr, opcode, RESPONSE_REFUSED)
		return
	}
	
	// Check if mapping already exists
	existingMapping, index := s.stateManager.FindExistingMapping(addr.IP.String(), internalPort, externalPort, protocol)
	
	if existingMapping != nil {
		// Mapping exists, update its lifetime
		logVerbose("Mapping already exists, updating lifetime from %d to %d", existingMapping.Lifetime, lifetime)
		
		if lifetime == 0 {
			// Delete mapping
			logVerbose("Lifetime is 0, removing mapping")
			removedMapping, err := s.stateManager.RemoveMapping(index)
			if err != nil {
				log.Printf("Failed to remove mapping from state: %v", err)
				requestsTotal.WithLabelValues(protocol, "error_state").Inc()
				s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
				return
			}
			
			// Remove from nftables
			if err := s.nftManager.RemoveMapping(*removedMapping); err != nil {
				log.Printf("Failed to remove nftables rule: %v", err)
				// Try to restore the mapping in state
				s.stateManager.AddMapping(*removedMapping)
				requestsTotal.WithLabelValues(protocol, "error_nft").Inc()
				s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
				return
			}
		} else {
			// Update existing mapping
			if err := s.stateManager.UpdateMapping(index, lifetime); err != nil {
				log.Printf("Failed to update mapping: %v", err)
				requestsTotal.WithLabelValues(protocol, "error_state").Inc()
				s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
				return
			}
		}
	} else {
		// New mapping
		if lifetime == 0 {
			// Client is trying to delete a non-existent mapping
			logVerbose("Cannot delete non-existent mapping")
			requestsTotal.WithLabelValues(protocol, "error_refused").Inc()
			s.sendErrorResponse(addr, opcode, RESPONSE_REFUSED)
			return
		}
		
		mapping := Mapping{
			InternalIP:   addr.IP.String(),
			InternalPort: internalPort,
			ExternalPort: externalPort,
			Protocol:     protocol,
			Lifetime:     lifetime,
			CreatedAt:    time.Now(),
			ExpiresAt:    time.Now().Add(time.Duration(lifetime) * time.Second),
		}
		
		if err := s.nftManager.AddMapping(&mapping); err != nil {
			log.Printf("Failed to add nftables rule: %v", err)
			requestsTotal.WithLabelValues(protocol, "error_nft").Inc()
			s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
			return
		}
		
		logVerbose("nftables rule added, saving to state...")
		
		if err := s.stateManager.AddMapping(mapping); err != nil {
			log.Printf("Failed to save mapping: %v", err)
			s.nftManager.RemoveMapping(mapping)
			requestsTotal.WithLabelValues(protocol, "error_state").Inc()
			s.sendErrorResponse(addr, opcode, RESPONSE_RSRC)
			return
		}
	}
	
	logVerbose("Mapping saved to state, sending response...")
	
	response := make([]byte, 16)
	response[0] = NATPMP_VERSION
	response[1] = opcode + 128
	response[2] = 0
	response[3] = RESPONSE_SUCCESS
	
	epoch := uint32(time.Now().Unix())
	response[4] = byte(epoch >> 24)
	response[5] = byte(epoch >> 16)
	response[6] = byte(epoch >> 8)
	response[7] = byte(epoch)
	
	response[8] = byte(internalPort >> 8)
	response[9] = byte(internalPort)
	response[10] = byte(externalPort >> 8)
	response[11] = byte(externalPort)
	
	response[12] = byte(lifetime >> 24)
	response[13] = byte(lifetime >> 16)
	response[14] = byte(lifetime >> 8)
	response[15] = byte(lifetime)
	
	s.conn.WriteToUDP(response, addr)
	requestsTotal.WithLabelValues(protocol, "success").Inc()
	
	if lifetime > 0 {
		log.Printf("Port mapping created: %s:%d -> %s:%d (%s) for %d seconds",
			addr.IP, internalPort, s.getExternalIP(), externalPort, protocol, lifetime)
	} else {
		log.Printf("Port mapping removed: %s:%d -> %s:%d (%s)",
			addr.IP, internalPort, s.getExternalIP(), externalPort, protocol)
	}
	
	// Update port range usage metrics
	// Note: The metrics update is already handled in AddMapping after releasing the lock
	// which calls updateActiveMappingsMetrics. If we need port range usage specifically,
	// we should update that function to also call updatePortRangeUsage.
}

func (s *NATPMPServer) sendErrorResponse(addr *net.UDPAddr, opcode byte, resultCode byte) {
	response := make([]byte, 8)
	response[0] = NATPMP_VERSION
	response[1] = opcode + 128
	response[2] = 0
	response[3] = resultCode
	
	epoch := uint32(time.Now().Unix())
	response[4] = byte(epoch >> 24)
	response[5] = byte(epoch >> 16)
	response[6] = byte(epoch >> 8)
	response[7] = byte(epoch)
	
	s.conn.WriteToUDP(response, addr)
}

func (s *NATPMPServer) getExternalIP() net.IP {
	iface, err := net.InterfaceByName(s.config.ExternalInterface)
	if err != nil {
		return net.IPv4zero
	}
	
	addrs, err := iface.Addrs()
	if err != nil {
		return net.IPv4zero
	}
	
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil {
			return ipnet.IP
		}
	}
	
	return net.IPv4zero
}

func (s *NATPMPServer) isPortAllowed(port uint16) bool {
	for _, r := range s.config.AllowedPorts {
		if port >= r.Start && port <= r.End {
			return true
		}
	}
	return false
}

func (s *NATPMPServer) Shutdown() {
	log.Println("Cleaning up mappings...")
	if s.conn != nil {
		s.conn.Close()
	}
	
	mappings := s.stateManager.GetMappings()
	
	for _, m := range mappings {
		if err := s.nftManager.RemoveMapping(m); err != nil {
			log.Printf("Failed to remove mapping on shutdown: %v", err)
		} else {
			mappingsDeletedTotal.WithLabelValues(m.Protocol, "shutdown").Inc()
		}
	}
}

func cleanupExpiredMappings(sm *StateManager, nft *NFTablesManager, interval int) {
	ticker := time.NewTicker(time.Duration(interval) * time.Second)
	defer ticker.Stop()
	
	for range ticker.C {
		expired := sm.RemoveExpiredMappings()
		for _, m := range expired {
			log.Printf("Port mapping expired: %s:%d -> :%d (%s)",
				m.InternalIP, m.InternalPort, m.ExternalPort, m.Protocol)
			if err := nft.RemoveMapping(m); err != nil {
				log.Printf("Failed to remove nftables rule: %v", err)
			}
		}
	}
}