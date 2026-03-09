package tsnsrv

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"golang.org/x/exp/slog"
)

// ServiceError represents an error from a specific service
type ServiceError struct {
	ServiceName string
	Err         error
}

func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %q: %v", e.ServiceName, e.Err)
}

func (e *ServiceError) Unwrap() error {
	return e.Err
}

// Orchestrator manages multiple tsnsrv services running concurrently
type Orchestrator struct {
	services []*ValidTailnetSrv
}

// NewOrchestrator creates an orchestrator for the given services
func NewOrchestrator(services []*ValidTailnetSrv) *Orchestrator {
	return &Orchestrator{
		services: services,
	}
}

// Run starts all services concurrently and waits for all to complete or for the first error.
// If any service fails, the context is canceled to signal other services to stop.
// Returns the first error encountered, or nil if all services complete successfully.
func (o *Orchestrator) Run(ctx context.Context) error {
	if len(o.services) == 0 {
		return errors.New("no services to run")
	}

	// Single service optimization - run directly
	if len(o.services) == 1 {
		return o.services[0].Run(ctx)
	}

	// Multi-service mode
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	errChan := make(chan *ServiceError, len(o.services))

	// Start all services concurrently
	for _, svc := range o.services {
		wg.Add(1)
		go func(s *ValidTailnetSrv) {
			defer wg.Done()
			slog.Info("Starting service", "name", s.Name)
			if err := s.Run(ctx); err != nil {
				// Check if this is a context cancellation (expected during shutdown)
				if errors.Is(err, context.Canceled) {
					slog.Info("Service stopped", "name", s.Name)
					return
				}
				slog.Error("Service failed", "name", s.Name, "error", err)
				errChan <- &ServiceError{
					ServiceName: s.Name,
					Err:         err,
				}
				// Cancel context to stop other services
				cancel()
			}
		}(svc)
	}

	// Wait for first error or all services to complete
	go func() {
		wg.Wait()
		close(errChan)
	}()

	// Collect all errors
	var errs []error
	for err := range errChan {
		errs = append(errs, err)
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	return nil
}

// RunSingle is a convenience function for running a single service
func RunSingle(ctx context.Context, service *ValidTailnetSrv) error {
	return service.Run(ctx)
}

// RunMultiple is a convenience function for running multiple services
func RunMultiple(ctx context.Context, services []*ValidTailnetSrv) error {
	o := NewOrchestrator(services)
	return o.Run(ctx)
}
