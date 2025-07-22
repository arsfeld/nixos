package server

import (
	"html/template"
	"log"
	"net/http"
	"path/filepath"

	"github.com/gorilla/mux"
	"github.com/arosenfeld/nixos/packages/router_ui/config"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/crypto"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/db"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/server/handlers"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/server/middleware"
	"github.com/arosenfeld/nixos/packages/router_ui/internal/services"
)

type Server struct {
	config           *config.Config
	db               *db.DB
	router           *mux.Router
	templates        *template.Template
	encryptor        *crypto.AgeEncryptor
	vpnService       *services.VPNService
	nftService       *services.NFTService
	discoveryService *services.ClientDiscoveryService
}

func New(cfg *config.Config, database *db.DB) *Server {
	s := &Server{
		config: cfg,
		db:     database,
		router: mux.NewRouter(),
	}

	// Initialize encryptor (optional, will work without it)
	keyPath := filepath.Join(filepath.Dir(cfg.DBPath), "age.key")
	encryptor, err := crypto.NewAgeEncryptor(keyPath)
	if err != nil {
		log.Printf("Warning: Failed to initialize encryption: %v", err)
		log.Printf("VPN credentials will be stored in plain text")
	} else {
		s.encryptor = encryptor
	}

	// Initialize VPN service if enabled
	if cfg.EnableVPN {
		log.Println("Initializing VPN service...")
		
		// Create WireGuard config directory
		wgConfigDir := filepath.Join(filepath.Dir(cfg.DBPath), "wireguard")
		
		// Initialize VPN service
		s.vpnService = services.NewVPNService(database, wgConfigDir, encryptor)
		if err := s.vpnService.Start(); err != nil {
			log.Printf("Warning: Failed to start VPN service: %v", err)
			s.vpnService = nil
		}
		
		// Initialize NFT service
		s.nftService = services.NewNFTService()
		if err := s.nftService.Initialize(); err != nil {
			log.Printf("Warning: Failed to initialize NFT service: %v", err)
			s.nftService = nil
		}
	}
	
	// Initialize client discovery service
	log.Println("Initializing client discovery service...")
	s.discoveryService = services.NewClientDiscoveryService(database)
	if err := s.discoveryService.Start(); err != nil {
		log.Printf("Warning: Failed to start client discovery service: %v", err)
		s.discoveryService = nil
	}

	s.setupRoutes()
	return s
}

func (s *Server) Router() http.Handler {
	return s.router
}

func (s *Server) setupRoutes() {
	s.router.Use(middleware.Logger)
	s.router.Use(middleware.Recovery)

	if s.config.TailscaleAuth {
		s.router.Use(middleware.TailscaleAuth)
	}

	api := s.router.PathPrefix("/api").Subrouter()
	api.Use(middleware.JSON)

	vpnHandler := handlers.NewVPNHandler(s.db, s.encryptor, s.vpnService)
	api.HandleFunc("/vpn/providers", vpnHandler.ListProviders).Methods("GET")
	api.HandleFunc("/vpn/providers", vpnHandler.CreateProvider).Methods("POST")
	api.HandleFunc("/vpn/providers/{id}", vpnHandler.GetProvider).Methods("GET")
	api.HandleFunc("/vpn/providers/{id}", vpnHandler.UpdateProvider).Methods("PUT")
	api.HandleFunc("/vpn/providers/{id}", vpnHandler.DeleteProvider).Methods("DELETE")
	api.HandleFunc("/vpn/providers/{id}/toggle", vpnHandler.ToggleProvider).Methods("POST")
	api.HandleFunc("/vpn/status", vpnHandler.GetVPNStatus).Methods("GET")

	// Use new client handler with discovery service
	clientHandlerV2 := handlers.NewClientHandlerV2(s.discoveryService)
	api.HandleFunc("/clients", clientHandlerV2.ListClients).Methods("GET")
	api.HandleFunc("/clients/{mac}", clientHandlerV2.GetClient).Methods("GET")
	api.HandleFunc("/clients/{mac}", clientHandlerV2.UpdateClient).Methods("PUT")
	api.HandleFunc("/clients/stats", clientHandlerV2.GetClientStats).Methods("GET")
	
	// Keep old VPN mapping endpoint for compatibility
	clientHandler := handlers.NewClientHandler(s.db)
	api.HandleFunc("/clients/{mac}/vpn", clientHandler.UpdateVPNMapping).Methods("PUT")

	dashboardHandler := handlers.NewDashboardHandler(s.db)
	api.HandleFunc("/dashboard/stats", dashboardHandler.GetStats).Methods("GET")

	api.HandleFunc("/events", handlers.SSEHandler).Methods("GET")

	// Static file server with proper MIME types
	staticHandler := http.StripPrefix("/static/", http.FileServer(http.Dir("web/static")))
	s.router.PathPrefix("/static/").Handler(middleware.StaticFiles(staticHandler))

	s.router.HandleFunc("/", s.handleIndex).Methods("GET")
	s.router.HandleFunc("/dashboard", s.handleDashboard).Methods("GET")
	s.router.HandleFunc("/vpn", s.handleVPN).Methods("GET")
	s.router.HandleFunc("/clients", s.handleClients).Methods("GET")
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/dashboard", http.StatusTemporaryRedirect)
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	s.renderTemplate(w, "dashboard.html", map[string]interface{}{
		"Page": "dashboard",
	})
}

func (s *Server) handleVPN(w http.ResponseWriter, r *http.Request) {
	s.renderTemplate(w, "vpn.html", map[string]interface{}{
		"Page": "vpn",
	})
}

func (s *Server) handleClients(w http.ResponseWriter, r *http.Request) {
	s.renderTemplate(w, "clients.html", map[string]interface{}{
		"Page": "clients",
	})
}

func (s *Server) renderTemplate(w http.ResponseWriter, name string, data interface{}) {
	layoutPath := filepath.Join("web/templates", "layout.html")
	pagePath := filepath.Join("web/templates", name)
	
	tmpl, err := template.ParseFiles(layoutPath, pagePath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := tmpl.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
}

// Stop gracefully shuts down the server and its services
func (s *Server) Stop() error {
	var err error
	
	if s.vpnService != nil {
		if stopErr := s.vpnService.Stop(); stopErr != nil {
			err = stopErr
		}
	}
	
	if s.discoveryService != nil {
		if stopErr := s.discoveryService.Stop(); stopErr != nil && err == nil {
			err = stopErr
		}
	}
	
	return err
}