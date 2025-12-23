package main

import (
	"fmt"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// Request metrics
	requestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_requests_total",
			Help: "Total number of NAT-PMP requests",
		},
		[]string{"type", "result"},
	)

	// Active mappings gauge
	activeMappings = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "natpmp_active_mappings",
			Help: "Number of active port mappings",
		},
		[]string{"protocol"},
	)

	// Mapping lifecycle metrics
	mappingsCreatedTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_mappings_created_total",
			Help: "Total number of mappings created",
		},
		[]string{"protocol"},
	)

	mappingsExpiredTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_mappings_expired_total",
			Help: "Total number of mappings that expired",
		},
		[]string{"protocol"},
	)

	mappingsDeletedTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_mappings_deleted_total",
			Help: "Total number of mappings deleted",
		},
		[]string{"protocol", "reason"},
	)

	// Client metrics
	clientMappings = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "natpmp_client_mappings",
			Help: "Number of mappings per client IP",
		},
		[]string{"client_ip"},
	)

	// Individual mapping details
	mappingInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "natpmp_mapping_info",
			Help: "Information about individual port mappings",
		},
		[]string{"client_ip", "protocol", "external_port", "internal_port"},
	)

	// Port range usage
	portRangeUsage = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "natpmp_port_range_usage",
			Help: "Percentage of ports in use from allowed range",
		},
		[]string{"range"},
	)

	// State operations
	stateOperations = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_state_operations_total",
			Help: "Total number of state persistence operations",
		},
		[]string{"operation", "result"},
	)

	// NFTables operations
	nftablesOperations = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "natpmp_nftables_operations_total",
			Help: "Total number of nftables operations",
		},
		[]string{"operation", "result"},
	)

	// Request duration histogram
	requestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "natpmp_request_duration_seconds",
			Help:    "Duration of NAT-PMP request processing",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"type"},
	)
)

// Helper functions to update metrics

func updateActiveMappingsMetrics(mappings []Mapping) {
	tcpCount := 0
	udpCount := 0
	clientCounts := make(map[string]int)

	// Reset mapping info metric first
	mappingInfo.Reset()

	for _, m := range mappings {
		if m.Protocol == "tcp" {
			tcpCount++
		} else {
			udpCount++
		}
		clientCounts[m.InternalIP]++

		// Add individual mapping info
		mappingInfo.WithLabelValues(
			m.InternalIP,
			m.Protocol,
			fmt.Sprintf("%d", m.ExternalPort),
			fmt.Sprintf("%d", m.InternalPort),
		).Set(1)
	}

	activeMappings.WithLabelValues("tcp").Set(float64(tcpCount))
	activeMappings.WithLabelValues("udp").Set(float64(udpCount))

	// Reset all client metrics first
	clientMappings.Reset()
	for ip, count := range clientCounts {
		clientMappings.WithLabelValues(ip).Set(float64(count))
	}
}

func updatePortRangeUsage(mappings []Mapping, portRanges []PortRange) {
	// Count used ports per range
	for _, r := range portRanges {
		usedPorts := make(map[uint16]bool)
		for _, m := range mappings {
			if m.ExternalPort >= r.Start && m.ExternalPort <= r.End {
				usedPorts[m.ExternalPort] = true
			}
		}

		totalPorts := float64(r.End - r.Start + 1)
		usedCount := float64(len(usedPorts))
		usage := (usedCount / totalPorts) * 100.0

		rangeLabel := fmt.Sprintf("%d-%d", r.Start, r.End)
		portRangeUsage.WithLabelValues(rangeLabel).Set(usage)
	}
}
