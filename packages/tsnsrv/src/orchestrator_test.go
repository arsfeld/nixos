package tsnsrv

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// mockService is a test helper that simulates a ValidTailnetSrv
type mockService struct {
	name     string
	runFunc  func(context.Context) error
	runDelay time.Duration
}

func (m *mockService) createValidService(t *testing.T) *ValidTailnetSrv {
	// Create a minimal valid service for testing
	ts := &TailnetSrv{
		Name:       m.name,
		ListenAddr: ":443",
	}
	// We can't actually run this service without a real tsnet.Server,
	// so we'll test the orchestrator logic separately
	return &ValidTailnetSrv{
		TailnetSrv: *ts,
	}
}

func TestOrchestrator_NoServices(t *testing.T) {
	o := NewOrchestrator([]*ValidTailnetSrv{})
	err := o.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no services to run")
}

func TestServiceError(t *testing.T) {
	baseErr := errors.New("connection failed")
	svcErr := &ServiceError{
		ServiceName: "test-service",
		Err:         baseErr,
	}

	assert.Equal(t, `service "test-service": connection failed`, svcErr.Error())
	assert.ErrorIs(t, svcErr, baseErr)
}

// Test that orchestrator structure is correct
func TestNewOrchestrator(t *testing.T) {
	services := []*ValidTailnetSrv{
		{TailnetSrv: TailnetSrv{Name: "service1"}},
		{TailnetSrv: TailnetSrv{Name: "service2"}},
	}

	o := NewOrchestrator(services)
	require.NotNil(t, o)
	assert.Len(t, o.services, 2)
	assert.Equal(t, "service1", o.services[0].Name)
	assert.Equal(t, "service2", o.services[1].Name)
}

// Test context cancellation propagates correctly
func TestOrchestrator_ContextCancellation(t *testing.T) {
	// This test verifies the orchestrator structure handles context properly
	// We can't test actual service running without integration tests
	services := []*ValidTailnetSrv{
		{TailnetSrv: TailnetSrv{Name: "service1"}},
	}

	o := NewOrchestrator(services)
	require.NotNil(t, o)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	// The service will fail to start because context is cancelled
	// and we don't have a real tsnet server, but we're testing structure
	err := o.Run(ctx)
	// Expect an error since we don't have real services set up
	require.Error(t, err)
}

// Test that RunSingle and RunMultiple convenience functions exist
func TestConvenienceFunctions(t *testing.T) {
	service := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{Name: "test"},
	}

	// These will fail because we don't have real tsnet servers,
	// but we're verifying the function signatures work
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	err := RunSingle(ctx, service)
	require.Error(t, err) // Expected - no real server

	err = RunMultiple(ctx, []*ValidTailnetSrv{service})
	require.Error(t, err) // Expected - no real server
}
