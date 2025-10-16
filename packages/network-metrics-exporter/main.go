package main

import (
    "bufio"
    "context"
    "encoding/csv"
    "encoding/json"
    "bytes"
    "fmt"
    "io"
    "log"
    "net"
    "net/http"
    "os"
    "os/exec"
    "strconv"
    "regexp"
    "strings"
    "sync"
    "time"
    "sort"

	"github.com/grandcat/zeroconf"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/wimark/vendormap"
)

// Debug timing logs
var debugTiming = os.Getenv("DEBUG_TIMING") == "true"

// Helper for timing logs
func logTiming(format string, args ...interface{}) {
	if debugTiming {
		log.Printf("[TIMING] "+format, args...)
	}
}

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
    // LAN IPv4 prefix (e.g., 10.1.1)
    lanPrefix = func() string {
        p := os.Getenv("NETWORK_PREFIX")
        if p == "" {
            return "192.168.10"
        }
        return p
    }()
	
	// Traffic tracking for rate calculation
	trafficHistory     = make(map[string]*TrafficSnapshot)
	trafficHistoryLock sync.RWMutex
	
	// Client name cache that persists across restarts (keyed by MAC address)
	// Now includes timestamp and source for expiry and debugging
	clientNameCache     = make(map[string]*ClientNameCacheEntry) // MAC -> cache entry
	clientNameCacheLock sync.RWMutex
	clientNameCacheFile = "/var/lib/network-metrics-exporter/client-names.cache"
	cacheExpiryDuration = 24 * time.Hour // Cache entries expire after 24 hours
	
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

    // NetBIOS cache
    netbiosCache     = make(map[string]string) // IP -> name
    netbiosCacheLock sync.RWMutex
    
    // SSDP/UPnP cache
    ssdpCache     = make(map[string]*SSDPDevice) // IP -> device info
    ssdpCacheLock sync.RWMutex
    lastSSDPScan  time.Time
    
    // Metrics for name resolution coverage
    namesTotal = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "network_names_total",
        Help: "Total number of devices with resolved names",
    })

    namesBySource = promauto.NewGaugeVec(prometheus.GaugeOpts{
        Name: "network_names_by_source",
        Help: "Number of names resolved by each source",
    }, []string{"source"})

    // Cache performance metrics
    cacheHits = promauto.NewCounter(prometheus.CounterOpts{
        Name: "hostname_cache_hits_total",
        Help: "Total number of hostname cache hits",
    })

    cacheMisses = promauto.NewCounter(prometheus.CounterOpts{
        Name: "hostname_cache_misses_total",
        Help: "Total number of hostname cache misses",
    })

    cacheInvalidations = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "hostname_cache_invalidations_total",
        Help: "Total number of hostname cache invalidations by reason",
    }, []string{"reason"})

    cacheEntries = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "hostname_cache_entries",
        Help: "Current number of entries in hostname cache",
    })

    hostnameResolutionDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
        Name: "hostname_resolution_duration_seconds",
        Help: "Time taken to resolve hostnames by source",
        Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 2.0, 5.0},
    }, []string{"source"})

    hostnameResolutionSource = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "hostname_resolution_source_total",
        Help: "Count of hostname resolutions by source",
    }, []string{"source"})

    // Kea leases and DHCP hosts caches
    keaIPToName       = make(map[string]string)
    keaMacToName      = make(map[string]string)
    keaLastLoad       time.Time
    dhcpHostsIPToName = make(map[string]string)
    dhcpHostsLastLoad time.Time
    // Exporter-managed hosts file for Blocky
    exporterHostsPath = func() string {
        p := os.Getenv("EXPORTER_HOSTS_FILE")
        if p == "" {
            return "/var/lib/network-metrics-exporter/hosts"
        }
        return p
    }()
    // Kea control socket path (preferred when available)
    keaSocketPath = func() string {
        p := os.Getenv("KEA_SOCKET_PATH")
        if p == "" {
            return "/run/kea/kea-dhcp4.sock"
        }
        return p
    }()
)

type ClientInfo struct {
	IP            string
	Name          string
	DeviceType    string
	LastSeen      time.Time
}

type ClientNameCacheEntry struct {
	Hostname   string
	Source     string    // Source that provided this name (e.g., "kea-leases", "mdns", "cache")
	Timestamp  time.Time // When this entry was created/updated
	LastSeenIP string    // Last IP this MAC was seen at (for debugging)
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

type SSDPDevice struct {
	IP           string
	FriendlyName string
	ModelName    string
	Manufacturer string
	DeviceType   string
	UUID         string
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

	// Start periodic cache cleanup
	go runPeriodicCacheCleanup()

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
	go runPeriodicSSDPDiscovery()
	
	ticker := time.NewTicker(time.Duration(interval) * time.Second)
	defer ticker.Stop()

    for {
        updateMetrics()
        // After each metrics update, write a consolidated hosts file for DNS
        // This provides LAN names to Blocky even when DHCP lacks hostnames
        safelyWriteHostsFile()
        <-ticker.C
    }
}

func updateMetrics() {
	var overallStart time.Time
	if debugTiming {
		overallStart = time.Now()
	}
	
	// Update traffic metrics from nftables
	var start time.Time
	if debugTiming {
		start = time.Now()
	}
	updateTrafficMetrics()
	if debugTiming {
		logTiming(" updateTrafficMetrics took %v", time.Since(start))
	}

	// Update connection counts
	if debugTiming {
		start = time.Now()
	}
	updateConnectionCounts()
	if debugTiming {
		logTiming(" updateConnectionCounts took %v", time.Since(start))
	}

	// Update client status
	if debugTiming {
		start = time.Now()
	}
	updateClientStatus()
	if debugTiming {
		logTiming(" updateClientStatus took %v", time.Since(start))
	}
	
	// Update WAN IP
	if debugTiming {
		start = time.Now()
	}
	updateWanIp()
	if debugTiming {
		logTiming(" updateWanIp took %v", time.Since(start))
	}
	
	// Update client database metrics
	if debugTiming {
		start = time.Now()
	}
	updateClientDatabaseMetrics()
	if debugTiming {
		logTiming(" updateClientDatabaseMetrics took %v", time.Since(start))
	}
	
	if debugTiming {
		logTiming(" Total updateMetrics took %v", time.Since(overallStart))
	}
}

func updateTrafficMetrics() {
	start := time.Now()
	cmd := exec.Command("nft", "-j", "list", "chain", "inet", "filter", "CLIENT_TRAFFIC")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("Error getting nftables rules: %v", err)
		return
	}
	logTiming("nft command took %v", time.Since(start))

	start = time.Now()
	var nftOutput NftOutput
	if err := json.Unmarshal(output, &nftOutput); err != nil {
		log.Printf("Error parsing nftables JSON: %v", err)
		return
	}
	logTiming(" JSON unmarshal took %v", time.Since(start))

	// Load client database once before processing rules
	clientDB := loadClientDatabase()

	currentTime := time.Now()
	
	// Track current values per IP
	currentTraffic := make(map[string]*TrafficSnapshot)
	
	start = time.Now()
	ruleCount := 0

	clientsLock.Lock()
	defer clientsLock.Unlock()

	for _, item := range nftOutput.Nftables {
		ruleCount++
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
	logTiming(" Processing %d nftables rules took %v", ruleCount, time.Since(start))
	
	// Calculate rates
	start = time.Now()
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
	logTiming(" Rate calculations took %v", time.Since(start))
}

func updateConnectionCounts() {
	start := time.Now()
	cmd := exec.Command("conntrack", "-L", "-o", "extended")
	output, err := cmd.Output()
	logTiming(" conntrack command took %v", time.Since(start))
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
	start = time.Now()
	connectionCounts := make(map[string]int)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	lineCount := 0
	
	for scanner.Scan() {
		lineCount++
		line := scanner.Text()
            // Extract IPs from conntrack output
            // Look for src= and dst= patterns
            matches := conntrackIPRegex.FindAllStringSubmatch(line, -1)
            
            for _, match := range matches {
                ip := match[1]
                // Only count local network IPs
                if strings.HasPrefix(ip, lanPrefix+".") {
                    connectionCounts[ip]++
                }
            }
        }
	logTiming(" Parsing %d conntrack lines took %v", lineCount, time.Since(start))

	start = time.Now()
	clientsLock.RLock()
	defer clientsLock.RUnlock()

	// Reset metrics first
	clientActiveConnections.Reset()

	// Update metrics for known clients
	for ip, client := range clients {
		count := connectionCounts[ip]
		clientActiveConnections.WithLabelValues(ip, client.Name, client.DeviceType).Set(float64(count))
	}
	logTiming(" Updating connection metrics took %v", time.Since(start))
}

func updateClientStatus() {
	// Get ARP table
	start := time.Now()
	cmd := exec.Command("ip", "neigh", "show")
	output, err := cmd.Output()
	logTiming(" ip neigh show took %v", time.Since(start))
	if err != nil {
		log.Printf("Error getting ARP table: %v", err)
		return
	}

	// Parse ARP entries
	start = time.Now()
	arpEntries := make(map[string]bool)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	lineCount := 0
	
	for scanner.Scan() {
		lineCount++
		line := scanner.Text()
        // Look for REACHABLE, STALE, DELAY, or PROBE states
        if strings.Contains(line, "REACHABLE") || 
           strings.Contains(line, "STALE") || 
           strings.Contains(line, "DELAY") || 
           strings.Contains(line, "PROBE") {
            fields := strings.Fields(line)
            if len(fields) > 0 {
                ip := fields[0]
                if strings.HasPrefix(ip, lanPrefix+".") {
                    arpEntries[ip] = true
                }
            }
        }
    }
	logTiming(" Parsing %d ARP entries took %v", lineCount, time.Since(start))

	start = time.Now()
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
	logTiming(" Updating client status metrics took %v", time.Since(start))
}

func getClientName(ip string) string {
	start := time.Now()
	var resolvedSource string
	defer func() {
		elapsed := time.Since(start)
		if elapsed > 10*time.Millisecond {
			log.Printf("[TIMING WARNING] getClientName(%s) took %v (source: %s)", ip, elapsed, resolvedSource)
		}
		if resolvedSource != "" {
			hostnameResolutionDuration.WithLabelValues(resolvedSource).Observe(elapsed.Seconds())
			hostnameResolutionSource.WithLabelValues(resolvedSource).Inc()
		}
	}()

    // First get MAC address for this IP
    macAddr := getMacAddress(ip)

    // Check cache by MAC address with expiry validation
    if macAddr != "" {
        clientNameCacheLock.RLock()
        if cacheEntry, exists := clientNameCache[macAddr]; exists {
            // Check if cache entry has expired
            if time.Since(cacheEntry.Timestamp) < cacheExpiryDuration {
                cachedName := cacheEntry.Hostname
                clientNameCacheLock.RUnlock()

                // Cache hit - valid entry
                cacheHits.Inc()
                resolvedSource = "cache"
                updateNameSourceMetric("cache")
                log.Printf("[CACHE HIT] MAC %s -> %s (age: %v, source: %s)",
                    macAddr, cachedName, time.Since(cacheEntry.Timestamp).Round(time.Minute), cacheEntry.Source)
                return cachedName
            } else {
                // Cache entry expired
                clientNameCacheLock.RUnlock()
                clientNameCacheLock.Lock()
                delete(clientNameCache, macAddr)
                clientNameCacheLock.Unlock()

                cacheInvalidations.WithLabelValues("expired").Inc()
                log.Printf("[CACHE EXPIRED] MAC %s -> %s (age: %v)",
                    macAddr, cacheEntry.Hostname, time.Since(cacheEntry.Timestamp).Round(time.Minute))
            }
        } else {
            clientNameCacheLock.RUnlock()
        }

        // Cache miss
        cacheMisses.Inc()
    }

    // Refresh DHCP-backed sources periodically (authoritative names)
    ensureDhcpSourcesLoaded()

    // 1) Authoritative: dhcp-hosts (statics)
    if name := getNameFromDhcpHostsCache(ip); name != "" {
        if macAddr != "" {
            updateClientNameCache(macAddr, name, "dhcp-hosts", ip)
        }
        resolvedSource = "dhcp-hosts"
        updateNameSourceMetric("dhcp-hosts")
        return name
    }

    // 2) Authoritative: Kea leases (memfile). Prefer MAC map first, then IP map.
    if name := getNameFromKeaCaches(ip, macAddr); name != "" {
        if macAddr != "" {
            updateClientNameCache(macAddr, name, "kea-leases", ip)
        }
        resolvedSource = "kea-leases"
        updateNameSourceMetric("kea-leases")
        return name
    }

    // 3) Check SSDP/UPnP cache (common for media devices, IoT)
    ssdpCacheLock.RLock()
    if ssdpDevice, exists := ssdpCache[ip]; exists {
        ssdpCacheLock.RUnlock()
        if ssdpDevice.FriendlyName != "" {
            if macAddr != "" {
                updateClientNameCache(macAddr, ssdpDevice.FriendlyName, "ssdp", ip)
            }
            resolvedSource = "ssdp"
            updateNameSourceMetric("ssdp")
            return ssdpDevice.FriendlyName
        }
    } else {
        ssdpCacheLock.RUnlock()
    }

    // 4) Check mDNS cache (fast, common for Apple/IoT/media)
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
            if macAddr != "" {
                updateClientNameCache(macAddr, name, "mdns", ip)
            }
            resolvedSource = "mdns"
            updateNameSourceMetric("mdns")
            return name
        }
    } else {
        mdnsCacheLock.RUnlock()
    }

    // 5) Check reverse DNS cache (PTR via system resolver)
    dnsResolveCacheLock.RLock()
    if resolvedName, exists := dnsResolveCache[ip]; exists {
        dnsResolveCacheLock.RUnlock()
        if resolvedName != "" {
            if macAddr != "" {
                updateClientNameCache(macAddr, resolvedName, "dns", ip)
            }
            resolvedSource = "dns"
            updateNameSourceMetric("dns")
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

    // 6) Try NetBIOS (Windows/Samba) via nmblookup
    if nb := getNameFromNetBIOS(ip); nb != "" {
        if macAddr != "" {
            updateClientNameCache(macAddr, nb, "netbios", ip)
        }
        resolvedSource = "netbios"
        updateNameSourceMetric("netbios")
        return nb
    }

    // 7) Check /etc/hosts or custom hosts
    hostsFile := os.Getenv("HOSTS_FILE")
    if hostsFile == "" {
        hostsFile = "/etc/hosts"
    }
    if hostName := getNameFromFile(hostsFile, ip, 0, 1); hostName != "" {
        if macAddr != "" {
            updateClientNameCache(macAddr, hostName, "hosts-file", ip)
        }
        resolvedSource = "hosts-file"
        updateNameSourceMetric("hosts-file")
        return hostName
    }

    // 8) Static clients database (explicit mapping)
    if dbName := getNameFromStaticClients(ip); dbName != "" {
        if macAddr != "" {
            updateClientNameCache(macAddr, dbName, "static-db", ip)
        }
        resolvedSource = "static-db"
        updateNameSourceMetric("static-db")
        return dbName
    }

    // 9) Friendly fallback: vendor + mac tail
    if macAddr != "" {
        vend := getVendorForIP(ip)
        vshort := ""
        fields := strings.Fields(vend)
        if len(fields) > 0 {
            vshort = strings.ToLower(fields[0])
            // Clean up malformed vendor names
            vshort = strings.TrimPrefix(vshort, "(")
            vshort = strings.TrimSuffix(vshort, ")")
            // Remove any remaining special characters
            vshort = regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(vshort, "")
        }
        m := strings.ReplaceAll(macAddr, ":", "")
        if len(m) >= 4 {
            m = m[len(m)-4:]
        }
        // Ensure we have a valid vendor prefix
        if vshort == "" || vshort == "unknown" {
            vshort = "device"
        }
        fallback := fmt.Sprintf("%s-%s", vshort, m)
        updateClientNameCache(macAddr, fallback, "fallback", ip)
        resolvedSource = "fallback"
        updateNameSourceMetric("fallback")
        return fallback
    }

    resolvedSource = "unknown"
    updateNameSourceMetric("unknown")
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

// getNameFromNetBIOS uses nmblookup to query NetBIOS name; caches results
func getNameFromNetBIOS(ip string) string {
    // Check cache first
    netbiosCacheLock.RLock()
    if n, ok := netbiosCache[ip]; ok {
        netbiosCacheLock.RUnlock()
        return n
    }
    netbiosCacheLock.RUnlock()

    // Ensure nmblookup exists
    if _, err := exec.LookPath("nmblookup"); err != nil {
        return ""
    }

    // Run nmblookup -A <ip> with a short timeout
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    out, err := exec.CommandContext(ctx, "nmblookup", "-A", ip).CombinedOutput()
    if err != nil {
        return ""
    }

    name := parseNetBIOSName(string(out))
    if name != "" {
        netbiosCacheLock.Lock()
        netbiosCache[ip] = name
        netbiosCacheLock.Unlock()
    }
    return name
}

// parseNetBIOSName extracts the UNIQUE <00> workstation name from nmblookup output
func parseNetBIOSName(out string) string {
    scanner := bufio.NewScanner(strings.NewReader(out))
    for scanner.Scan() {
        line := scanner.Text()
        // Example: "MYPC         <00>  UNIQUE      Registered"
        if strings.Contains(line, "<00>") && strings.Contains(line, "UNIQUE") {
            fields := strings.Fields(line)
            if len(fields) > 0 {
                return fields[0]
            }
        }
    }
    return ""
}

// getNameFromStaticClients loads the static clients DB and returns a hostname for the IP
func getNameFromStaticClients(ip string) string {
    db := loadClientDatabase()
    if entry, ok := db[ip]; ok {
        return entry.Hostname
    }
    return ""
}

// getNameFromKeaLeases parses Kea memfile leases CSV and returns hostname for an IP
func getNameFromKeaLeases(ip string) string {
    leasesFile := os.Getenv("KEA_LEASES_CSV")
    if leasesFile == "" {
        leasesFile = "/var/lib/kea/kea-leases4.csv"
    }
    f, err := os.Open(leasesFile)
    if err != nil {
        return ""
    }
    defer f.Close()

    scanner := bufio.NewScanner(f)
    for scanner.Scan() {
        line := scanner.Text()
        if strings.HasPrefix(line, "#") || line == "" {
            continue
        }
        // Kea memfile CSV default order:
        // ip,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,...
        parts := strings.Split(line, ",")
        if len(parts) < 10 {
            continue
        }
        if parts[0] == ip {
            name := strings.TrimSpace(parts[8])
            name = strings.Trim(name, "\"")
            name = strings.TrimSuffix(name, ".lan")
            // Filter to active, non-expired leases only
            state := strings.TrimSpace(parts[9])
            expireStr := strings.TrimSpace(parts[4])
            if expireTs, err := strconv.ParseInt(expireStr, 10, 64); err == nil {
                if state == "0" && time.Unix(expireTs, 0).After(time.Now()) {
                    if name != "" && name != "*" && name != "null" {
                        return name
                    }
                    return ""
                }
            }
            return ""
        }
    }
    return ""
}

// ensureDhcpSourcesLoaded refreshes caches from dhcp-hosts and Kea leases periodically
func ensureDhcpSourcesLoaded() {
    // dhcp-hosts every 30s
    if time.Since(dhcpHostsLastLoad) > 30*time.Second {
        loadDhcpHostsCache()
    }
    // Kea leases every 30s
    if time.Since(keaLastLoad) > 30*time.Second {
        loadKeaLeasesCache()
    }
}

func loadDhcpHostsCache() {
    filename := os.Getenv("DHCP_HOSTS_FILE")
    if filename == "" {
        filename = "/var/lib/kea/dhcp-hosts"
    }
    f, err := os.Open(filename)
    if err != nil {
        // Probably not present; update timestamp and keep
        dhcpHostsLastLoad = time.Now()
        return
    }
    defer f.Close()
    m := make(map[string]string)
    scanner := bufio.NewScanner(f)
    for scanner.Scan() {
        line := strings.TrimSpace(scanner.Text())
        if line == "" || strings.HasPrefix(line, "#") {
            continue
        }
        fields := strings.Fields(line)
        if len(fields) >= 2 {
            ip := fields[0]
            name := strings.TrimSuffix(fields[1], ".lan")
            if name != "" && net.ParseIP(ip) != nil {
                m[ip] = name
            }
        }
    }
    dhcpHostsIPToName = m
    dhcpHostsLastLoad = time.Now()
}

// loadKeaLeasesCache parses the memfile CSV and builds best-name maps for IP and MAC
func loadKeaLeasesCache() {
    // First try the Kea control socket for authoritative active leases
    if tryLoadKeaViaSocket() {
        keaLastLoad = time.Now()
        return
    }

    leasesFile := os.Getenv("KEA_LEASES_CSV")
    if leasesFile == "" {
        leasesFile = "/var/lib/kea/kea-leases4.csv"
    }

    // Determine processing order per Kea memfile LFC design:
    // If <filename>.completed exists:
    //   [<filename>.completed, <filename>]
    // else:
    //   [<filename>.2, <filename>.1, <filename>]
    order := []string{}
    if _, err := os.Stat(leasesFile + ".completed"); err == nil {
        order = append(order, leasesFile+".completed")
        if _, err := os.Stat(leasesFile); err == nil {
            order = append(order, leasesFile)
        }
    } else {
        if _, err := os.Stat(leasesFile + ".2"); err == nil {
            order = append(order, leasesFile+".2")
        }
        if _, err := os.Stat(leasesFile + ".1"); err == nil {
            order = append(order, leasesFile+".1")
        }
        if _, err := os.Stat(leasesFile); err == nil {
            order = append(order, leasesFile)
        }
    }
    if len(order) == 0 {
        keaLastLoad = time.Now()
        return
    }

    ipBestExpire := make(map[string]int64)
    macBestExpire := make(map[string]int64)
    ipToName := make(map[string]string)
    macToName := make(map[string]string)
    now := time.Now()

    process := func(path string) {
        f, err := os.Open(path)
        if err != nil {
            return
        }
        defer f.Close()
        r := csv.NewReader(f)
        r.FieldsPerRecord = -1
        header, err := r.Read()
        if err != nil {
            return
        }
        // header indices
        find := func(name string) int {
            for i, h := range header {
                if h == name {
                    return i
                }
            }
            return -1
        }
        ipIdx := find("address")
        macIdx := find("hwaddr")
        hostIdx := find("hostname")
        expIdx := find("expire")
        stateIdx := find("state")
        if ipIdx < 0 || macIdx < 0 || hostIdx < 0 || expIdx < 0 || stateIdx < 0 {
            return
        }
        for {
            rec, err := r.Read()
            if err == io.EOF {
                break
            }
            if err != nil || len(rec) <= stateIdx {
                continue
            }
            ip := strings.TrimSpace(rec[ipIdx])
            name := strings.TrimSpace(rec[hostIdx])
            name = strings.Trim(name, "\"")
            mac := strings.ToLower(strings.TrimSpace(rec[macIdx]))
            if strings.HasSuffix(name, ".lan") {
                name = strings.TrimSuffix(name, ".lan")
            }
            if name == "" || name == "*" || strings.EqualFold(name, "null") {
                continue
            }
            expStr := strings.TrimSpace(rec[expIdx])
            st := strings.TrimSpace(rec[stateIdx])
            exp, _ := strconv.ParseInt(expStr, 10, 64)
            if st != "0" || exp <= 0 || time.Unix(exp, 0).Before(now) {
                continue
            }
            if ip != "" && net.ParseIP(ip) != nil {
                if exp > ipBestExpire[ip] {
                    ipBestExpire[ip] = exp
                    ipToName[ip] = name
                }
            }
            if mac != "" {
                if exp > macBestExpire[mac] {
                    macBestExpire[mac] = exp
                    macToName[mac] = name
                }
            }
        }
    }

    for _, p := range order {
        process(p)
    }

    keaIPToName = ipToName
    keaMacToName = macToName
    keaLastLoad = time.Now()
}

// tryLoadKeaViaSocket queries the Kea control socket for lease4-get-all and
// populates keaIPToName/keaMacToName if successful.
func tryLoadKeaViaSocket() bool {
    // Check socket existence early
    if _, err := os.Stat(keaSocketPath); err != nil {
        return false
    }
    // Dial UNIX socket
    conn, err := net.DialTimeout("unix", keaSocketPath, 500*time.Millisecond)
    if err != nil {
        return false
    }
    defer conn.Close()
    // Request all leases
    req := []byte(`{ "command": "lease4-get-all", "service": ["dhcp4"] }` + "\n")
    conn.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
    if _, err := conn.Write(req); err != nil {
        return false
    }
    // Read response
    conn.SetReadDeadline(time.Now().Add(800 * time.Millisecond))
    resp, err := io.ReadAll(conn)
    if err != nil || len(resp) == 0 {
        return false
    }
    // Minimal structs for JSON parsing
    type lease struct {
        IPAddress string `json:"ip-address"`
        Hostname  string `json:"hostname"`
        HWAddress string `json:"hw-address"`
        State     int    `json:"state"`
        ValidLft  int    `json:"valid-lft"`
    }
    var parsed struct {
        Arguments struct {
            Leases []lease `json:"leases"`
        } `json:"arguments"`
        Result int `json:"result"`
    }
    if err := json.Unmarshal(resp, &parsed); err != nil || parsed.Result != 0 {
        return false
    }
    ipToName := make(map[string]string)
    macToName := make(map[string]string)
    for _, l := range parsed.Arguments.Leases {
        if l.State != 0 || l.IPAddress == "" {
            continue
        }
        name := strings.TrimSpace(strings.Trim(l.Hostname, "\""))
        if strings.HasSuffix(name, ".lan") { name = strings.TrimSuffix(name, ".lan") }
        if name == "" || strings.EqualFold(name, "null") || name == "*" {
            continue
        }
        if net.ParseIP(l.IPAddress) != nil {
            ipToName[l.IPAddress] = name
        }
        mac := strings.ToLower(strings.TrimSpace(l.HWAddress))
        if mac != "" {
            macToName[mac] = name
        }
    }
    // Only consider it a success if we found at least one mapping
    if len(ipToName) == 0 && len(macToName) == 0 {
        return false
    }
    keaIPToName = ipToName
    keaMacToName = macToName
    return true
}

func getNameFromDhcpHostsCache(ip string) string {
    if name, ok := dhcpHostsIPToName[ip]; ok {
        return name
    }
    return ""
}

func getNameFromKeaCaches(ip, mac string) string {
    if mac != "" {
        if name, ok := keaMacToName[strings.ToLower(mac)]; ok && name != "" {
            return name
        }
    }
    if name, ok := keaIPToName[ip]; ok && name != "" {
        return name
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

	// Parse cache file
	// New format: MAC|Hostname|Source|Timestamp|LastSeenIP
	// Old formats: MAC|Name or IP|Name (for backward compatibility)
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	loadedCount := 0
	expiredCount := 0

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.Split(line, "|")

		// New format with 5 fields
		if len(parts) == 5 {
			mac := parts[0]
			hostname := parts[1]
			source := parts[2]
			timestampStr := parts[3]
			lastSeenIP := parts[4]

			if !strings.Contains(mac, ":") {
				continue // Skip invalid MAC
			}

			timestamp, err := time.Parse(time.RFC3339, timestampStr)
			if err != nil {
				// Try parsing as Unix timestamp for compatibility
				if unixTime, err := strconv.ParseInt(timestampStr, 10, 64); err == nil {
					timestamp = time.Unix(unixTime, 0)
				} else {
					log.Printf("Warning: Invalid timestamp in cache for MAC %s: %v", mac, err)
					continue
				}
			}

			// Check if expired
			if time.Since(timestamp) >= cacheExpiryDuration {
				expiredCount++
				log.Printf("[CACHE LOAD] Skipping expired entry: MAC %s -> %s (age: %v)",
					mac, hostname, time.Since(timestamp).Round(time.Minute))
				continue
			}

			clientNameCache[mac] = &ClientNameCacheEntry{
				Hostname:   hostname,
				Source:     source,
				Timestamp:  timestamp,
				LastSeenIP: lastSeenIP,
			}
			loadedCount++

		} else if len(parts) == 2 {
			// Old format: MAC|Name or IP|Name
			key := parts[0]
			name := parts[1]

			// Check if it's a MAC address (contains colons)
			if strings.Contains(key, ":") {
				// Old format without timestamp - use current time but mark as migrated
				clientNameCache[key] = &ClientNameCacheEntry{
					Hostname:   name,
					Source:     "migrated",
					Timestamp:  time.Now(),
					LastSeenIP: "",
				}
				loadedCount++
			} else if net.ParseIP(key) != nil {
				// It's an IP address from very old format - try to get MAC and convert
				mac := getMacAddress(key)
				if mac != "" {
					clientNameCache[mac] = &ClientNameCacheEntry{
						Hostname:   name,
						Source:     "migrated",
						Timestamp:  time.Now(),
						LastSeenIP: key,
					}
					loadedCount++
				}
			}
		}
	}

	log.Printf("Loaded %d client names from cache (%d expired entries skipped)", loadedCount, expiredCount)
	cacheEntries.Set(float64(len(clientNameCache)))
}

func saveClientNameCache() {
	clientNameCacheLock.RLock()
	defer clientNameCacheLock.RUnlock()

	var lines []string
	// Add header comment
	lines = append(lines, "# network-metrics-exporter client name cache")
	lines = append(lines, "# Format: MAC|Hostname|Source|Timestamp|LastSeenIP")

	// Sort MACs for consistent output
	macs := make([]string, 0, len(clientNameCache))
	for mac := range clientNameCache {
		macs = append(macs, mac)
	}
	sort.Strings(macs)

	for _, mac := range macs {
		entry := clientNameCache[mac]
		// Only save entries that look like MAC addresses
		if !strings.Contains(mac, ":") {
			continue
		}

		// Skip expired entries
		if time.Since(entry.Timestamp) >= cacheExpiryDuration {
			continue
		}

		// Format: MAC|Hostname|Source|Timestamp|LastSeenIP
		line := fmt.Sprintf("%s|%s|%s|%s|%s",
			mac,
			entry.Hostname,
			entry.Source,
			entry.Timestamp.Format(time.RFC3339),
			entry.LastSeenIP,
		)
		lines = append(lines, line)
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

func updateClientNameCache(mac, name, source, ip string) {
	if mac == "" || name == "" || name == "unknown" {
		return
	}

	entry := &ClientNameCacheEntry{
		Hostname:   name,
		Source:     source,
		Timestamp:  time.Now(),
		LastSeenIP: ip,
	}

	clientNameCacheLock.Lock()
	// Check if this is an update to existing entry
	if existing, exists := clientNameCache[mac]; exists {
		// Log if the name changed from a different source
		if existing.Hostname != name {
			log.Printf("[CACHE UPDATE] MAC %s: %s -> %s (source: %s -> %s)",
				mac, existing.Hostname, name, existing.Source, source)
			cacheInvalidations.WithLabelValues("updated").Inc()
		}
	}
	clientNameCache[mac] = entry
	cacheEntries.Set(float64(len(clientNameCache)))
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
        strings.Contains(lowerHostname, "samsung-tv"), strings.Contains(lowerHostname, "lg-tv"),
        strings.Contains(lowerHostname, "sonos"), strings.Contains(lowerHostname, "bravia"),
        strings.Contains(lowerHostname, "hisense"), strings.Contains(lowerHostname, "tcl"):
        return "media"
		
	// Gaming consoles
	case strings.Contains(lowerHostname, "playstation"), strings.Contains(lowerHostname, "ps4"), strings.Contains(lowerHostname, "ps5"),
		strings.Contains(lowerHostname, "xbox"),
		strings.Contains(lowerHostname, "nintendo"), strings.Contains(lowerHostname, "switch"):
		return "gaming"
		
    // Printers
    case strings.Contains(lowerHostname, "printer"),
        strings.HasPrefix(lowerHostname, "hp"), strings.Contains(lowerHostname, "officejet"),
        strings.Contains(lowerHostname, "laserjet"), strings.Contains(lowerHostname, "deskjet"),
        strings.Contains(lowerHostname, "brother"),
        strings.Contains(lowerHostname, "canon"),
        strings.Contains(lowerHostname, "epson"):
        return "printer"
		
    // Phones
    case strings.Contains(lowerHostname, "android"), strings.Contains(lowerHostname, "phone"),
        strings.Contains(lowerHostname, "pixel"), strings.Contains(lowerHostname, "galaxy"),
        strings.Contains(lowerHostname, "oneplus"), strings.Contains(lowerHostname, "xiaomi"),
        strings.Contains(lowerHostname, "huawei"), strings.Contains(lowerHostname, "oppo"),
        strings.Contains(lowerHostname, "moto"), strings.Contains(lowerHostname, "nokia"):
        return "phone"
		
	// Network equipment
	case strings.Contains(lowerHostname, "switch"), strings.Contains(lowerHostname, "router"),
		strings.Contains(lowerHostname, "ap-"), strings.Contains(lowerHostname, "unifi"):
		return "network"
		
    // Computers
    case strings.Contains(lowerHostname, "desktop"), strings.Contains(lowerHostname, "laptop"),
        strings.Contains(lowerHostname, "pc-"), strings.Contains(lowerHostname, "workstation"),
        strings.Contains(lowerHostname, "thinkpad"), strings.Contains(lowerHostname, "xps"),
        strings.Contains(lowerHostname, "latitude"), strings.Contains(lowerHostname, "precision"):
        return "computer"

    // Storage / servers
    case strings.Contains(lowerHostname, "nas"), strings.Contains(lowerHostname, "synology"),
        strings.Contains(lowerHostname, "qnap"), strings.Contains(lowerHostname, "truenas"),
        strings.Contains(lowerHostname, "unraid"):
        return "storage"
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
	
    // Always consider MAC OUI vendor as a supplemental hint
    if macAddr != "" {
        if vendor == "" {
            vendor = vendormap.MACVendor(macAddr)
            lowerVendor = strings.ToLower(vendor)
        } else {
            // If vendor already known, also try OUI to enrich matching
            if v := vendormap.MACVendor(macAddr); v != "" {
                lowerVendor = strings.ToLower(v)
            }
        }
        if lowerVendor != "" {
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

            // Google / Nest
            case strings.Contains(lowerVendor, "google"), strings.Contains(lowerVendor, "nest"):
                return "iot"

            // Phones (manufacturers)
            case strings.Contains(lowerVendor, "xiaomi"), strings.Contains(lowerVendor, "huawei"),
                strings.Contains(lowerVendor, "oneplus"), strings.Contains(lowerVendor, "oppo"),
                strings.Contains(lowerVendor, "motorola"):
                return "phone"

            // Storage vendors
            case strings.Contains(lowerVendor, "synology"), strings.Contains(lowerVendor, "qnap"):
                return "storage"

            // Media devices / TVs
            case strings.Contains(lowerVendor, "roku"), strings.Contains(lowerVendor, "vizio"),
                strings.Contains(lowerVendor, "samsung"), strings.Contains(lowerVendor, "lg electronics"),
                strings.Contains(lowerVendor, "sony"):
                return "media"

            // Smart home
            case strings.Contains(lowerVendor, "belkin"), strings.Contains(lowerVendor, "tp-link"),
                strings.Contains(lowerVendor, "tuya"), strings.Contains(lowerVendor, "espressif"),
                strings.Contains(lowerVendor, "shelly"), strings.Contains(lowerVendor, "sonoff"):
                return "iot"

            // Network equipment vendors
            case strings.Contains(lowerVendor, "ubiquiti"), strings.Contains(lowerVendor, "cisco"),
                strings.Contains(lowerVendor, "netgear"), strings.Contains(lowerVendor, "asus"),
                strings.Contains(lowerVendor, "d-link"):
                return "network"

            // Gaming / XR
            case strings.Contains(lowerVendor, "nintendo"), strings.Contains(lowerVendor, "microsoft"),
                strings.Contains(lowerVendor, "sony interactive"), strings.Contains(lowerVendor, "valve"),
                strings.Contains(lowerVendor, "oculus"), strings.Contains(lowerVendor, "meta"):
                return "gaming"

            // Printers
            case strings.Contains(lowerVendor, "hewlett packard"), strings.Contains(lowerVendor, "hp inc"),
                strings.Contains(lowerVendor, "canon"), strings.Contains(lowerVendor, "epson"),
                strings.Contains(lowerVendor, "brother"):
                return "printer"

            // PCs
            case strings.Contains(lowerVendor, "dell"), strings.Contains(lowerVendor, "lenovo"),
                strings.Contains(lowerVendor, "hp inc"):
                return "computer"
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
	start := time.Now()
	clientDB := loadClientDatabase()
	logTiming(" loadClientDatabase took %v", time.Since(start))
	
	// Count total clients
	total := 0
	online := 0
	deviceTypes := make(map[string]int)
	
	// Count static clients
	start = time.Now()
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
	logTiming(" Processing %d static clients took %v", len(clientDB), time.Since(start))
	
	// Also count dynamic clients from current session
	start = time.Now()
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
	logTiming(" Processing dynamic clients took %v", time.Since(start))
	
	// Update metrics
	clientsTotal.Set(float64(total))
	clientsOnline.Set(float64(online))
	
	// Reset device type metrics
	clientsByType.Reset()
	for deviceType, count := range deviceTypes {
		clientsByType.WithLabelValues(deviceType).Set(float64(count))
	}
}

// safelyWriteHostsFile writes a consolidated hosts file mapping IP -> names.
// Format per line: "IP name name.lan". Only writes if content changed.
func safelyWriteHostsFile() {
    // Build a map of IP -> name using known clients
    clientsLock.RLock()
    ips := make([]string, 0, len(clients))
    for ip := range clients {
        ips = append(ips, ip)
    }
    clientsLock.RUnlock()

    // Sort IPs for stable output
    sort.Slice(ips, func(i, j int) bool { return ips[i] < ips[j] })

    var b strings.Builder
    // Header
    b.WriteString("# Generated by network-metrics-exporter\n")
    now := time.Now().Format(time.RFC3339)
    b.WriteString("# Updated: "+now+"\n")

    for _, ip := range ips {
        name := getClientName(ip)
        if name == "" || name == "unknown" {
            continue
        }
        // sanitize whitespace
        name = strings.TrimSpace(name)
        if name == "" {
            continue
        }
        // Write "IP name name.lan"
        b.WriteString(ip)
        b.WriteByte(' ')
        b.WriteString(name)
        b.WriteByte(' ')
        // append ".lan" suffix if not already a FQDN ending with known dot
        if !strings.HasSuffix(name, ".lan") {
            b.WriteString(name)
            b.WriteString(".lan")
        } else {
            b.WriteString(name)
        }
        b.WriteByte('\n')
    }

    // Read current content (if any)
    _ = os.MkdirAll("/var/lib/network-metrics-exporter", 0755)
    newData := []byte(b.String())
    oldData, _ := os.ReadFile(exporterHostsPath)
    if bytes.Equal(newData, oldData) {
        return
    }
    tmp := exporterHostsPath + ".tmp"
    if err := os.WriteFile(tmp, newData, 0644); err != nil {
        log.Printf("Error writing hosts file: %v", err)
        return
    }
    if err := os.Rename(tmp, exporterHostsPath); err != nil {
        log.Printf("Error renaming hosts file: %v", err)
    }
}

// runPeriodicCacheCleanup runs cache cleanup on a fixed schedule
func runPeriodicCacheCleanup() {
	// Initial delay before first cleanup
	time.Sleep(10 * time.Minute)

	// Run cleanup every hour
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()

	for {
		cleanupClientNameCache()
		<-ticker.C
	}
}

// cleanupClientNameCache removes expired and stale entries from the cache
func cleanupClientNameCache() {
	start := time.Now()
	log.Printf("[CACHE CLEANUP] Starting cache cleanup")

	clientNameCacheLock.Lock()
	defer clientNameCacheLock.Unlock()

	initialCount := len(clientNameCache)
	expiredCount := 0
	staleCount := 0

	// Get current ARP table to check which MACs are still active
	cmd := exec.Command("ip", "neigh", "show")
	output, err := cmd.Output()
	activeMacs := make(map[string]bool)

	if err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(output)))
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			for i, field := range fields {
				if field == "lladdr" && i+1 < len(fields) {
					mac := strings.ToLower(fields[i+1])
					activeMacs[mac] = true
				}
			}
		}
	}

	// Iterate through cache and remove expired/stale entries
	for mac, entry := range clientNameCache {
		// Remove expired entries (>24 hours old)
		if time.Since(entry.Timestamp) >= cacheExpiryDuration {
			delete(clientNameCache, mac)
			expiredCount++
			log.Printf("[CACHE CLEANUP] Removed expired entry: MAC %s -> %s (age: %v)",
				mac, entry.Hostname, time.Since(entry.Timestamp).Round(time.Hour))
			cacheInvalidations.WithLabelValues("cleanup-expired").Inc()
			continue
		}

		// Remove stale entries: MACs not seen in ARP for >7 days
		macLower := strings.ToLower(mac)
		if !activeMacs[macLower] && time.Since(entry.Timestamp) > 7*24*time.Hour {
			delete(clientNameCache, mac)
			staleCount++
			log.Printf("[CACHE CLEANUP] Removed stale entry: MAC %s -> %s (not seen in ARP, age: %v)",
				mac, entry.Hostname, time.Since(entry.Timestamp).Round(time.Hour))
			cacheInvalidations.WithLabelValues("cleanup-stale").Inc()
		}
	}

	finalCount := len(clientNameCache)
	removedCount := initialCount - finalCount

	log.Printf("[CACHE CLEANUP] Completed: removed %d entries (%d expired, %d stale), %d remain (took %v)",
		removedCount, expiredCount, staleCount, finalCount, time.Since(start).Round(time.Millisecond))

	// Update metrics
	cacheEntries.Set(float64(finalCount))

	// Save cleaned cache
	if removedCount > 0 {
		// Need to release lock before saving (saveClientNameCache acquires read lock)
		clientNameCacheLock.Unlock()
		saveClientNameCache()
		clientNameCacheLock.Lock()
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
	start := time.Now()
	defer func() {
		logTiming(" Total runArpScan took %v", time.Since(start))
	}()
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
	cmdStart := time.Now()
	cmd := exec.Command("arp-scan", "-l", "-I", iface, "--retry=2", "--timeout=200")
	output, err := cmd.Output()
	logTiming(" arp-scan command took %v", time.Since(cmdStart))
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
	parseStart := time.Now()
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
	logTiming(" Parsing arp-scan output took %v", time.Since(parseStart))
	
	// Update cache
	arpScanCacheLock.Lock()
	arpScanCache = newCache
	lastArpScan = currentTime
	arpScanCacheLock.Unlock()
	
	log.Printf("ARP scan completed: found %d devices", len(newCache))
}

// discoverMDNS performs mDNS discovery to find devices on the network
func discoverMDNS() {
	start := time.Now()
	defer func() {
		logTiming(" Total discoverMDNS took %v", time.Since(start))
	}()
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
					// Log any entry found
					if debugTiming {
						logTiming(" mDNS found entry: %s at %v", entry.Instance, entry.AddrIPv4)
					}
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
								log.Printf("mDNS discovered: %s (%s) at %s", entry.Instance, service, ip.String())
							}
							cacheMutex.Unlock()
						} else if debugTiming {
							logTiming(" mDNS IP %s not in network %s", ip.String(), networkPrefix)
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
			// Get MAC for this IP to cache properly
			mac := getMacAddress(ip)
			if mac != "" {
				updateClientNameCache(mac, resolvedName, "dns-background", ip)
			}
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

// runPeriodicSSDPDiscovery runs SSDP discovery on a fixed schedule
func runPeriodicSSDPDiscovery() {
	// Initial delay to avoid all discovery running at startup
	time.Sleep(2 * time.Minute)
	
	// Run every 10 minutes (less frequent than mDNS as it's more disruptive)
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	
	for {
		discoverSSDP()
		<-ticker.C
	}
}

// discoverSSDP performs SSDP discovery to find UPnP devices on the network
func discoverSSDP() {
	start := time.Now()
	defer func() {
		logTiming(" Total discoverSSDP took %v", time.Since(start))
	}()
	
	log.Println("Starting SSDP/UPnP discovery...")
	
	// Get network prefix from environment or use default
	networkPrefix := os.Getenv("NETWORK_PREFIX")
	if networkPrefix == "" {
		networkPrefix = "192.168.10"
	}
	
	newCache := make(map[string]*SSDPDevice)
	currentTime := time.Now()
	
	// Create UDP socket for SSDP M-SEARCH
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		log.Printf("Warning: Cannot create UDP socket for SSDP: %v", err)
		return
	}
	defer conn.Close()
	
	// SSDP multicast address
	ssdpAddr, _ := net.ResolveUDPAddr("udp", "239.255.255.250:1900")
	
	// M-SEARCH request
	searchMsg := []byte("M-SEARCH * HTTP/1.1\r\n" +
		"HOST: 239.255.255.250:1900\r\n" +
		"ST: ssdp:all\r\n" +
		"MAN: \"ssdp:discover\"\r\n" +
		"MX: 3\r\n\r\n")
	
	// Send M-SEARCH
	_, err = conn.WriteToUDP(searchMsg, ssdpAddr)
	if err != nil {
		log.Printf("Error sending SSDP M-SEARCH: %v", err)
		return
	}
	
	// Listen for responses (with timeout)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 4096)
	
	responseCount := 0
	for {
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				break // Timeout reached, done reading
			}
			log.Printf("Error reading SSDP response: %v", err)
			break
		}
		
		responseCount++
		// Check if response is from our network
		ip := addr.IP.String()
		if debugTiming {
			logTiming(" SSDP response %d from %s", responseCount, ip)
		}
		
		if !strings.HasPrefix(ip, networkPrefix) {
			if debugTiming {
				logTiming(" SSDP IP %s not in network %s", ip, networkPrefix)
			}
			continue
		}
		
		// Parse SSDP response to get LOCATION header
		response := string(buf[:n])
		location := extractSSDPHeader(response, "LOCATION")
		if location == "" {
			if debugTiming {
				logTiming(" SSDP response from %s has no LOCATION header", ip)
			}
			continue
		}
		
		log.Printf("SSDP found device at %s with location: %s", ip, location)
		
		// Fetch device description XML (with timeout)
		deviceInfo := fetchUPnPDeviceInfo(location)
		if deviceInfo != nil {
			deviceInfo.IP = ip
			deviceInfo.LastSeen = currentTime
			newCache[ip] = deviceInfo
			log.Printf("SSDP device identified: %s at %s", deviceInfo.FriendlyName, ip)
		} else if debugTiming {
			logTiming(" SSDP failed to fetch device info from %s", location)
		}
	}
	
	if debugTiming {
		logTiming(" SSDP received %d responses total", responseCount)
	}
	
	// Update cache
	ssdpCacheLock.Lock()
	ssdpCache = newCache
	lastSSDPScan = currentTime
	ssdpCacheLock.Unlock()
	
	log.Printf("SSDP discovery completed: found %d devices", len(newCache))
}

// extractSSDPHeader extracts a header value from SSDP response
func extractSSDPHeader(response, header string) string {
	lines := strings.Split(response, "\r\n")
	headerUpper := strings.ToUpper(header) + ":"
	for _, line := range lines {
		if strings.HasPrefix(strings.ToUpper(line), headerUpper) {
			return strings.TrimSpace(strings.SplitN(line, ":", 2)[1])
		}
	}
	return ""
}

// fetchUPnPDeviceInfo fetches and parses UPnP device description XML
func fetchUPnPDeviceInfo(location string) *SSDPDevice {
	// Use a short timeout for HTTP request
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(location)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	
	// Read response body
	bodyBytes, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024)) // Limit to 1MB
	if err != nil {
		return nil
	}
	
	// Parse XML to extract device info
	// Simple regex parsing for common fields (avoiding XML dependencies)
	body := string(bodyBytes)
	
	device := &SSDPDevice{}
	
	// Extract friendlyName
	if match := regexp.MustCompile(`<friendlyName>([^<]+)</friendlyName>`).FindStringSubmatch(body); len(match) > 1 {
		device.FriendlyName = strings.TrimSpace(match[1])
	}
	
	// Extract modelName
	if match := regexp.MustCompile(`<modelName>([^<]+)</modelName>`).FindStringSubmatch(body); len(match) > 1 {
		device.ModelName = strings.TrimSpace(match[1])
	}
	
	// Extract manufacturer
	if match := regexp.MustCompile(`<manufacturer>([^<]+)</manufacturer>`).FindStringSubmatch(body); len(match) > 1 {
		device.Manufacturer = strings.TrimSpace(match[1])
	}
	
	// Extract UDN (UUID)
	if match := regexp.MustCompile(`<UDN>uuid:([^<]+)</UDN>`).FindStringSubmatch(body); len(match) > 1 {
		device.UUID = strings.TrimSpace(match[1])
	}
	
	// Infer device type
	device.DeviceType = inferDeviceTypeFromUPnP(device.FriendlyName, device.ModelName, device.Manufacturer)
	
	// Only return if we got at least a friendly name
	if device.FriendlyName != "" {
		return device
	}
	
	return nil
}

// inferDeviceTypeFromUPnP infers device type from UPnP device info
func inferDeviceTypeFromUPnP(friendlyName, modelName, manufacturer string) string {
	combined := strings.ToLower(friendlyName + " " + modelName + " " + manufacturer)
	
	switch {
	case strings.Contains(combined, "tv"), strings.Contains(combined, "television"):
		return "media"
	case strings.Contains(combined, "roku"), strings.Contains(combined, "chromecast"), 
		strings.Contains(combined, "fire tv"), strings.Contains(combined, "apple tv"):
		return "media"
	case strings.Contains(combined, "printer"):
		return "printer"
	case strings.Contains(combined, "router"), strings.Contains(combined, "gateway"):
		return "network"
	case strings.Contains(combined, "nas"), strings.Contains(combined, "synology"), strings.Contains(combined, "qnap"):
		return "storage"
	case strings.Contains(combined, "playstation"), strings.Contains(combined, "xbox"), strings.Contains(combined, "nintendo"):
		return "gaming"
	case strings.Contains(combined, "sonos"), strings.Contains(combined, "speaker"):
		return "media"
	case strings.Contains(combined, "camera"):
		return "iot"
	default:
		return "unknown"
	}
}

// updateNameSourceMetric updates metrics tracking name resolution sources
func updateNameSourceMetric(source string) {
	// This is called frequently, so we'll batch updates
	// For now, just log at debug level
	if debugTiming {
		logTiming(" Name resolved from source: %s", source)
	}
}
