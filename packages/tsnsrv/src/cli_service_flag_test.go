package tsnsrv

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestServiceFlagParsing(t *testing.T) {
	tests := []struct {
		name        string
		flagValue   string
		expectError bool
		validate    func(*testing.T, ServiceConfig)
	}{
		{
			name:      "basic service",
			flagValue: "name=web,upstream=http://localhost:8080",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "web", svc.Name)
				assert.Equal(t, "http://localhost:8080", svc.Upstream)
				// Check defaults are set
				assert.Equal(t, ":443", svc.ListenAddr)
				assert.True(t, svc.RecommendedProxyHeaders)
				assert.True(t, svc.StripPrefix)
			},
		},
		{
			name:      "service with funnel",
			flagValue: "name=api,upstream=http://localhost:8081,funnel=true",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "api", svc.Name)
				assert.Equal(t, "http://localhost:8081", svc.Upstream)
				assert.True(t, svc.Funnel)
			},
		},
		{
			name:      "boolean variations",
			flagValue: "name=test,upstream=http://localhost:80,funnel=yes,ephemeral=1,funnelOnly=true",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.True(t, svc.Funnel)
				assert.True(t, svc.Ephemeral)
				assert.True(t, svc.FunnelOnly)
			},
		},
		{
			name:      "boolean false variations",
			flagValue: "name=test,upstream=http://localhost:80,funnel=no,ephemeral=0,stripPrefix=false",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.False(t, svc.Funnel)
				assert.False(t, svc.Ephemeral)
				assert.False(t, svc.StripPrefix)
			},
		},
		{
			name:      "duration parsing",
			flagValue: "name=test,upstream=http://localhost:80,timeout=2m,whoisTimeout=500ms",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, 2*time.Minute, svc.Timeout)
				assert.Equal(t, 500*time.Millisecond, svc.WhoisTimeout)
			},
		},
		{
			name:      "custom listen address",
			flagValue: "name=test,upstream=http://localhost:80,listenAddr=:8443",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, ":8443", svc.ListenAddr)
			},
		},
		{
			name:      "auth configuration",
			flagValue: "name=test,upstream=http://localhost:80,authURL=http://authelia:9091,authPath=/api/verify,authTimeout=10s",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "http://authelia:9091", svc.AuthURL)
				assert.Equal(t, "/api/verify", svc.AuthPath)
				assert.Equal(t, 10*time.Second, svc.AuthTimeout)
			},
		},
		{
			name:      "TLS options",
			flagValue: "name=test,upstream=http://localhost:80,certificateFile=/path/cert.pem,keyFile=/path/key.pem",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "/path/cert.pem", svc.CertificateFile)
				assert.Equal(t, "/path/key.pem", svc.KeyFile)
			},
		},
		{
			name:      "state and auth key paths",
			flagValue: "name=test,upstream=http://localhost:80,stateDir=/var/lib/tsnsrv,authkeyPath=/etc/tsnsrv/key",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "/var/lib/tsnsrv", svc.StateDir)
				assert.Equal(t, "/etc/tsnsrv/key", svc.AuthkeyPath)
			},
		},
		{
			name:        "prometheusAddr is not valid in service flags (process-level only)",
			flagValue:   "name=test,upstream=http://localhost:80,prometheusAddr=:9100",
			expectError: true,
		},
		{
			name:        "missing name",
			flagValue:   "upstream=http://localhost:8080",
			expectError: true,
		},
		{
			name:        "missing upstream",
			flagValue:   "name=web",
			expectError: true,
		},
		{
			name:        "invalid boolean",
			flagValue:   "name=test,upstream=http://localhost:80,funnel=maybe",
			expectError: true,
		},
		{
			name:        "invalid duration",
			flagValue:   "name=test,upstream=http://localhost:80,timeout=notaduration",
			expectError: true,
		},
		{
			name:        "unknown key",
			flagValue:   "name=test,upstream=http://localhost:80,unknownKey=value",
			expectError: true,
		},
		{
			name:        "invalid format (no equals)",
			flagValue:   "name=test,upstream=http://localhost:80,invalidpair",
			expectError: true,
		},
		{
			name:        "invalid tag format",
			flagValue:   "name=test,upstream=http://localhost:80,tag=invalid",
			expectError: true,
		},
		{
			name:      "valid tag format",
			flagValue: "name=test,upstream=http://localhost:80,tag=tag:srv",
			validate: func(t *testing.T, svc ServiceConfig) {
				require.Len(t, svc.Tags, 1)
				assert.Equal(t, "tag:srv", svc.Tags[0])
			},
		},
		{
			name:      "upstream TCP addr",
			flagValue: "name=test,upstream=http://localhost:80,upstreamTCPAddr=127.0.0.1:8080",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "127.0.0.1:8080", svc.UpstreamTCPAddr)
			},
		},
		{
			name:      "upstream Unix addr",
			flagValue: "name=test,upstream=http://localhost:80,upstreamUnixAddr=/var/run/app.sock",
			validate: func(t *testing.T, svc ServiceConfig) {
				assert.Equal(t, "/var/run/app.sock", svc.UpstreamUnixAddr)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var flags serviceFlags
			err := flags.Set(tt.flagValue)

			if tt.expectError {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			require.Len(t, flags, 1)

			if tt.validate != nil {
				tt.validate(t, flags[0])
			}
		})
	}
}

func TestServiceFlagMultipleTags(t *testing.T) {
	var flags serviceFlags

	// First service with one tag
	err := flags.Set("name=web,upstream=http://localhost:8080,tag=tag:srv")
	require.NoError(t, err)

	// Second service with multiple tags (need multiple calls for multiple tags)
	err = flags.Set("name=api,upstream=http://localhost:8081,tag=tag:api,tag=tag:prod")
	require.NoError(t, err)

	require.Len(t, flags, 2)

	// First service
	assert.Equal(t, "web", flags[0].Name)
	require.Len(t, flags[0].Tags, 1)
	assert.Equal(t, "tag:srv", flags[0].Tags[0])

	// Second service
	assert.Equal(t, "api", flags[1].Name)
	require.Len(t, flags[1].Tags, 2)
	assert.Equal(t, "tag:api", flags[1].Tags[0])
	assert.Equal(t, "tag:prod", flags[1].Tags[1])
}

func TestServiceFlagPrefixes(t *testing.T) {
	var flags serviceFlags

	err := flags.Set("name=web,upstream=http://localhost:8080,prefix=/api,prefix=funnel:/public")
	require.NoError(t, err)

	require.Len(t, flags, 1)
	assert.Equal(t, "web", flags[0].Name)
	require.Len(t, flags[0].Prefixes, 2)
	assert.Equal(t, "/api", flags[0].Prefixes[0])
	assert.Equal(t, "funnel:/public", flags[0].Prefixes[1])
}

func TestServiceFlagHeaders(t *testing.T) {
	var flags serviceFlags

	err := flags.Set("name=web,upstream=http://localhost:8080,upstreamHeader=X-Custom:value1,authCopyHeader=Remote-User:value2")
	require.NoError(t, err)

	require.Len(t, flags, 1)
	assert.Equal(t, "web", flags[0].Name)

	// Check upstream headers
	require.NotNil(t, flags[0].UpstreamHeaders)
	assert.Equal(t, "value1", flags[0].UpstreamHeaders["X-Custom"])

	// Check auth copy headers
	require.NotNil(t, flags[0].AuthCopyHeaders)
	assert.Equal(t, "value2", flags[0].AuthCopyHeaders["Remote-User"])
}

func TestServiceFlagHeaderInvalidFormat(t *testing.T) {
	var flags serviceFlags

	// Missing colon in header
	err := flags.Set("name=web,upstream=http://localhost:8080,upstreamHeader=InvalidHeader")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "header format")
}

func TestServiceFlagString(t *testing.T) {
	var flags serviceFlags

	// Empty
	assert.Equal(t, "", flags.String())

	// Single service
	err := flags.Set("name=web,upstream=http://localhost:8080")
	require.NoError(t, err)
	assert.Equal(t, "web->http://localhost:8080", flags.String())

	// Multiple services
	err = flags.Set("name=api,upstream=http://localhost:8081")
	require.NoError(t, err)
	assert.Equal(t, "web->http://localhost:8080; api->http://localhost:8081", flags.String())
}

func TestMultiServiceCLIMode(t *testing.T) {
	tests := []struct {
		name        string
		args        []string
		expectError bool
		expectCount int
		validate    func(*testing.T, []*ValidTailnetSrv)
	}{
		{
			name: "single service via -service flag",
			args: []string{
				"tsnsrv",
				"-service", "name=web,upstream=http://localhost:8080",
			},
			expectCount: 1,
			validate: func(t *testing.T, services []*ValidTailnetSrv) {
				assert.Equal(t, "web", services[0].Name)
				assert.Equal(t, "http://localhost:8080", services[0].DestURL.String())
			},
		},
		{
			name: "multiple services via repeated -service flag",
			args: []string{
				"tsnsrv",
				"-service", "name=web,upstream=http://localhost:8080,funnel=true",
				"-service", "name=api,upstream=http://localhost:8081,funnel=false",
			},
			expectCount: 2,
			validate: func(t *testing.T, services []*ValidTailnetSrv) {
				assert.Equal(t, "web", services[0].Name)
				assert.True(t, services[0].Funnel)
				assert.Equal(t, "api", services[1].Name)
				assert.False(t, services[1].Funnel)
			},
		},
		{
			name: "service with auth config",
			args: []string{
				"tsnsrv",
				"-service", "name=web,upstream=http://localhost:8080,authURL=http://authelia:9091,authBypassForTailnet=true",
			},
			expectCount: 1,
			validate: func(t *testing.T, services []*ValidTailnetSrv) {
				assert.Equal(t, "http://authelia:9091", services[0].AuthURL)
				assert.True(t, services[0].AuthBypassForTailnet)
			},
		},
		{
			name: "cannot mix -config and -service",
			args: []string{
				"tsnsrv",
				"-config", "config.yaml",
				"-service", "name=web,upstream=http://localhost:8080",
			},
			expectError: true,
		},
		{
			name: "cannot mix legacy flags with -service",
			args: []string{
				"tsnsrv",
				"-name", "legacy",
				"-service", "name=web,upstream=http://localhost:8080",
			},
			expectError: true,
		},
		{
			name: "legacy single-service mode still works",
			args: []string{
				"tsnsrv",
				"-name", "legacy",
				"-funnel",
				"http://localhost:8080",
			},
			expectCount: 1,
			validate: func(t *testing.T, services []*ValidTailnetSrv) {
				assert.Equal(t, "legacy", services[0].Name)
				assert.True(t, services[0].Funnel)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			services, _, _, err := TailnetSrvsFromArgs(tt.args)

			if tt.expectError {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			require.Len(t, services, tt.expectCount)

			if tt.validate != nil {
				tt.validate(t, services)
			}
		})
	}
}
