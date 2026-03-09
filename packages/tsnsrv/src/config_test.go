package tsnsrv

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadConfig(t *testing.T) {
	tests := []struct {
		name        string
		configYAML  string
		wantErr     bool
		errContains string
		validate    func(*testing.T, *Config)
	}{
		{
			name: "valid multi-service config",
			configYAML: `
services:
  - name: service1
    upstream: http://localhost:8080
    funnel: true
    authURL: http://authelia:9091
    authCopyHeaders:
      Remote-User: ""
      Remote-Groups: ""
    prefixes:
      - /app1
  - name: service2
    upstream: http://localhost:8081
    funnel: true
    prefixes:
      - /app2
`,
			wantErr: false,
			validate: func(t *testing.T, cfg *Config) {
				require.Len(t, cfg.Services, 2)
				assert.Equal(t, "service1", cfg.Services[0].Name)
				assert.Equal(t, "http://localhost:8080", cfg.Services[0].Upstream)
				assert.True(t, cfg.Services[0].Funnel)
				assert.Equal(t, "http://authelia:9091", cfg.Services[0].AuthURL)
				assert.Len(t, cfg.Services[0].AuthCopyHeaders, 2)
				assert.Len(t, cfg.Services[0].Prefixes, 1)

				assert.Equal(t, "service2", cfg.Services[1].Name)
				assert.Equal(t, "http://localhost:8081", cfg.Services[1].Upstream)
			},
		},
		{
			name: "single service config",
			configYAML: `
services:
  - name: myservice
    upstream: http://localhost:9000
    ephemeral: true
    tags:
      - tag:production
`,
			wantErr: false,
			validate: func(t *testing.T, cfg *Config) {
				require.Len(t, cfg.Services, 1)
				assert.Equal(t, "myservice", cfg.Services[0].Name)
				assert.True(t, cfg.Services[0].Ephemeral)
				assert.Len(t, cfg.Services[0].Tags, 1)
				assert.Equal(t, "tag:production", cfg.Services[0].Tags[0])
			},
		},
		{
			name: "no services",
			configYAML: `
services: []
`,
			wantErr:     true,
			errContains: "at least one service",
		},
		{
			name: "duplicate service names",
			configYAML: `
services:
  - name: duplicate
    upstream: http://localhost:8080
  - name: duplicate
    upstream: http://localhost:8081
`,
			wantErr:     true,
			errContains: "duplicate service name",
		},
		{
			name: "missing service name",
			configYAML: `
services:
  - upstream: http://localhost:8080
`,
			wantErr:     true,
			errContains: "needs a -name",
		},
		{
			name: "missing upstream",
			configYAML: `
services:
  - name: test
`,
			wantErr:     true,
			errContains: "upstream URL is required",
		},
		{
			name: "invalid plaintext with funnel",
			configYAML: `
services:
  - name: test
    upstream: http://localhost:8080
    plaintext: true
    funnel: true
`,
			wantErr:     true,
			errContains: "can not serve plaintext on a funnel",
		},
		{
			name: "funnelOnly without funnel",
			configYAML: `
services:
  - name: test
    upstream: http://localhost:8080
    funnelOnly: true
`,
			wantErr:     true,
			errContains: "funnel is required if -funnelOnly",
		},
		{
			name: "invalid tag format",
			configYAML: `
services:
  - name: test
    upstream: http://localhost:8080
    tags:
      - invalidtag
`,
			wantErr:     true,
			errContains: "tags must start with 'tag:'",
		},
		{
			name: "both TCP and Unix addresses",
			configYAML: `
services:
  - name: test
    upstream: http://localhost:8080
    upstreamTCPAddr: "localhost:9000"
    upstreamUnixAddr: "/tmp/socket"
`,
			wantErr:     true,
			errContains: "only proxy to one address at a time",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create temp file with config
			tmpDir := t.TempDir()
			configPath := filepath.Join(tmpDir, "config.yaml")
			err := os.WriteFile(configPath, []byte(tt.configYAML), 0600)
			require.NoError(t, err)

			// Load config
			cfg, err := LoadConfig(configPath)

			if tt.wantErr {
				require.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
				return
			}

			require.NoError(t, err)
			if tt.validate != nil {
				tt.validate(t, cfg)
			}
		})
	}
}

func TestServiceConfigToTailnetSrv(t *testing.T) {
	sc := ServiceConfig{
		Name:     "test-service",
		Upstream: "http://localhost:8080",
		Funnel:   true,
		Tags:     []string{"tag:production", "tag:web"},
		Prefixes: []string{"/api", "funnel:/public"},
		UpstreamHeaders: map[string]string{
			"X-Custom": "value",
		},
		AuthURL: "http://authelia:9091",
		AuthCopyHeaders: map[string]string{
			"Remote-User": "",
		},
		WhoisTimeout: 2 * time.Second,
		AuthTimeout:  10 * time.Second,
	}

	ts := sc.ToTailnetSrv()

	assert.Equal(t, "test-service", ts.Name)
	assert.True(t, ts.Funnel)
	assert.Equal(t, ":443", ts.ListenAddr) // Default
	assert.Equal(t, "http://authelia:9091", ts.AuthURL)
	assert.Equal(t, "/api/authz/forward-auth", ts.AuthPath) // Default
	assert.Equal(t, 2*time.Second, ts.WhoisTimeout)
	assert.Equal(t, 10*time.Second, ts.AuthTimeout)
	assert.Len(t, ts.Tags, 2)
	assert.Len(t, ts.AllowedPrefixes, 2)
	assert.NotNil(t, ts.UpstreamHeaders)
	assert.NotNil(t, ts.AuthCopyHeaders)
}

func TestServiceConfigDefaults(t *testing.T) {
	sc := ServiceConfig{
		Name:     "test",
		Upstream: "http://localhost:8080",
		AuthURL:  "http://authelia:9091",
	}

	ts := sc.ToTailnetSrv()

	// Check defaults are applied
	assert.Equal(t, ":443", ts.ListenAddr)
	assert.Equal(t, "/api/authz/forward-auth", ts.AuthPath)
	assert.Equal(t, 5*time.Second, ts.AuthTimeout)
	assert.Equal(t, 1*time.Second, ts.WhoisTimeout)
	assert.Equal(t, 1*time.Minute, ts.Timeout)
}

func TestConfigPrometheusAddr(t *testing.T) {
	tests := []struct {
		name             string
		configYAML       string
		expectedPromAddr string
	}{
		{
			name: "with prometheusAddr set",
			configYAML: `
prometheusAddr: ":8888"
services:
  - name: test
    upstream: http://localhost:8080
`,
			expectedPromAddr: ":8888",
		},
		{
			name: "without prometheusAddr (uses empty string, default applied in cli.go)",
			configYAML: `
services:
  - name: test
    upstream: http://localhost:8080
`,
			expectedPromAddr: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tmpDir := t.TempDir()
			configPath := filepath.Join(tmpDir, "config.yaml")
			err := os.WriteFile(configPath, []byte(tt.configYAML), 0600)
			require.NoError(t, err)

			cfg, err := LoadConfig(configPath)
			require.NoError(t, err)

			assert.Equal(t, tt.expectedPromAddr, cfg.PrometheusAddr)
		})
	}
}
