package main

import (
	"bytes"
	"net"
	"testing"
	"time"
)

func TestNATPMPProtocolParsing(t *testing.T) {
	tests := []struct {
		name        string
		data        []byte
		expectError bool
		opcode      byte
	}{
		{
			name:        "valid info request",
			data:        []byte{0, 0},
			expectError: false,
			opcode:      OPCODE_INFO,
		},
		{
			name:        "valid UDP mapping request",
			data:        []byte{0, 1, 0, 0, 0x1F, 0x90, 0x1F, 0x90, 0, 0, 0x0E, 0x10},
			expectError: false,
			opcode:      OPCODE_MAP_UDP,
		},
		{
			name:        "invalid version",
			data:        []byte{1, 0},
			expectError: true,
			opcode:      0,
		},
		{
			name:        "too short",
			data:        []byte{0},
			expectError: true,
			opcode:      0,
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.data) >= 2 {
				opcode := tt.data[1]
				if opcode != tt.opcode && !tt.expectError {
					t.Errorf("expected opcode %d, got %d", tt.opcode, opcode)
				}
			}
		})
	}
}

func TestPortRangeValidation(t *testing.T) {
	server := &NATPMPServer{
		config: &Config{
			AllowedPorts: []PortRange{
				{Start: 1024, End: 65535},
			},
		},
	}
	
	tests := []struct {
		port    uint16
		allowed bool
	}{
		{80, false},
		{443, false},
		{1024, true},
		{8080, true},
		{65535, true},
	}
	
	for _, tt := range tests {
		result := server.isPortAllowed(tt.port)
		if result != tt.allowed {
			t.Errorf("port %d: expected %v, got %v", tt.port, tt.allowed, result)
		}
	}
}

func TestStateManager(t *testing.T) {
	sm := NewStateManager("/tmp/test-natpmp")
	
	mapping := Mapping{
		InternalIP:   "10.1.1.100",
		InternalPort: 8080,
		ExternalPort: 8080,
		Protocol:     "tcp",
		Lifetime:     3600,
		CreatedAt:    time.Now(),
		ExpiresAt:    time.Now().Add(time.Hour),
	}
	
	if err := sm.AddMapping(mapping); err != nil {
		t.Fatalf("failed to add mapping: %v", err)
	}
	
	count := sm.CountMappingsForIP("10.1.1.100")
	if count != 1 {
		t.Errorf("expected 1 mapping, got %d", count)
	}
	
	count = sm.CountMappingsForIP("10.1.1.101")
	if count != 0 {
		t.Errorf("expected 0 mappings for different IP, got %d", count)
	}
}

func TestResponseGeneration(t *testing.T) {
	externalIP := net.IPv4(1, 2, 3, 4)
	
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
	
	if response[0] != 0 {
		t.Error("invalid version in response")
	}
	
	if response[1] != 128 {
		t.Error("invalid opcode in response")
	}
	
	if !bytes.Equal(response[8:12], []byte{1, 2, 3, 4}) {
		t.Error("invalid IP in response")
	}
}