package main

import (
	"context"
	"errors"
	"log"
	"os"

	"github.com/boinkor-net/tsnsrv"
	"github.com/peterbourgon/ff/v3/ffcli"
)

func main() {
	services, prometheusAddr, cmd, err := tsnsrv.TailnetSrvsFromArgs(os.Args)
	if err != nil {
		log.Fatalf("Invalid CLI usage. Errors:\n%v\n\n%v", errors.Unwrap(err), ffcli.DefaultUsageFunc(cmd))
	}

	ctx := context.Background()

	// Start prometheus/pprof server once at process level
	if err := tsnsrv.StartPrometheusServer(ctx, prometheusAddr); err != nil {
		log.Fatalf("Failed to start prometheus server: %v", err)
	}

	// Use orchestrator for both single and multi-service modes
	orchestrator := tsnsrv.NewOrchestrator(services)
	if err := orchestrator.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
