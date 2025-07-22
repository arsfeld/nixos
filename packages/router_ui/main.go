package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/arosenfeld/nixos/packages/router_ui/config"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/server"
)

func main() {
	var (
		configFile = flag.String("config", "", "Path to configuration file")
		port       = flag.String("port", "4000", "HTTP server port")
		dbPath     = flag.String("db", "/var/lib/router-ui/db", "BadgerDB data directory")
		enableVPN  = flag.Bool("enable-vpn", false, "Enable VPN management functionality")
	)
	flag.Parse()

	cfg := &config.Config{
		Port:      *port,
		DBPath:    *dbPath,
		EnableVPN: *enableVPN,
	}

	if *configFile != "" {
		if err := cfg.LoadFromFile(*configFile); err != nil {
			log.Fatalf("Failed to load config: %v", err)
		}
	}
	
	// Set defaults for any missing values
	cfg.SetDefaults()

	database, err := db.New(cfg.DBPath)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer database.Close()

	srv := server.New(cfg, database)

	httpServer := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      srv.Router(),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("Starting server on port %s", cfg.Port)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed to start: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")

	// Stop VPN service first
	if err := srv.Stop(); err != nil {
		log.Printf("Error stopping VPN service: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}