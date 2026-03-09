package tsnsrv

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTailnetSrvsFromArgs_ConfigMode(t *testing.T) {
	configYAML := `
services:
  - name: service1
    upstream: http://localhost:8080
    funnel: true
  - name: service2
    upstream: http://localhost:8081
`

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	err := os.WriteFile(configPath, []byte(configYAML), 0600)
	require.NoError(t, err)

	services, _, cmd, err := TailnetSrvsFromArgs([]string{"tsnsrv", "-config", configPath})
	require.NoError(t, err)
	require.NotNil(t, cmd)
	require.Len(t, services, 2)

	assert.Equal(t, "service1", services[0].Name)
	assert.True(t, services[0].Funnel)
	assert.Equal(t, "http://localhost:8080", services[0].DestURL.String())

	assert.Equal(t, "service2", services[1].Name)
	assert.Equal(t, "http://localhost:8081", services[1].DestURL.String())
}

func TestTailnetSrvsFromArgs_CLIMode(t *testing.T) {
	services, _, cmd, err := TailnetSrvsFromArgs([]string{
		"tsnsrv",
		"-name", "test-service",
		"-funnel",
		"http://localhost:9000",
	})
	require.NoError(t, err)
	require.NotNil(t, cmd)
	require.Len(t, services, 1)

	assert.Equal(t, "test-service", services[0].Name)
	assert.True(t, services[0].Funnel)
	assert.Equal(t, "http://localhost:9000", services[0].DestURL.String())
}

func TestTailnetSrvsFromArgs_ConfigAndCLIError(t *testing.T) {
	configYAML := `
services:
  - name: service1
    upstream: http://localhost:8080
`

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	err := os.WriteFile(configPath, []byte(configYAML), 0600)
	require.NoError(t, err)

	// Try to use both config and CLI flags
	_, _, _, err = TailnetSrvsFromArgs([]string{
		"tsnsrv",
		"-config", configPath,
		"-name", "test",
		"http://localhost:8080",
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cannot use -config with other CLI flags")
}

func TestTailnetSrvFromArgs_BackwardCompatibility(t *testing.T) {
	// Test that the original function still works
	service, _, cmd, err := TailnetSrvFromArgs([]string{
		"tsnsrv",
		"-name", "compat-test",
		"http://localhost:7000",
	})
	require.NoError(t, err)
	require.NotNil(t, cmd)
	require.NotNil(t, service)

	assert.Equal(t, "compat-test", service.Name)
	assert.Equal(t, "http://localhost:7000", service.DestURL.String())
}

func TestTailnetSrvFromArgs_ConfigWithMultipleServicesError(t *testing.T) {
	configYAML := `
services:
  - name: service1
    upstream: http://localhost:8080
  - name: service2
    upstream: http://localhost:8081
`

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	err := os.WriteFile(configPath, []byte(configYAML), 0600)
	require.NoError(t, err)

	// TailnetSrvFromArgs (singular) should fail with multiple services
	_, _, _, err = TailnetSrvFromArgs([]string{"tsnsrv", "-config", configPath})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "expected single service, got 2")
}

func TestTailnetSrvsFromArgs_InvalidConfig(t *testing.T) {
	configYAML := `
services:
  - name: test
    # Missing upstream
`

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	err := os.WriteFile(configPath, []byte(configYAML), 0600)
	require.NoError(t, err)

	_, _, _, err = TailnetSrvsFromArgs([]string{"tsnsrv", "-config", configPath})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "upstream URL is required")
}
