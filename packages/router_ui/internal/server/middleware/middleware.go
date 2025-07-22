package middleware

import (
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"
)

func Logger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.RequestURI, time.Since(start))
	})
}

func Recovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				log.Printf("panic: %v", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func JSON(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		next.ServeHTTP(w, r)
	})
}

func TailscaleAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check for Tailscale headers
		tsUser := r.Header.Get("Tailscale-User-Login")
		
		if tsUser == "" {
			// Check if request is from local network
			if !strings.HasPrefix(r.RemoteAddr, "192.168.") && 
			   !strings.HasPrefix(r.RemoteAddr, "10.") &&
			   !strings.HasPrefix(r.RemoteAddr, "127.") {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
		}
		
		next.ServeHTTP(w, r)
	})
}

func StaticFiles(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Get file extension
		ext := strings.ToLower(filepath.Ext(r.URL.Path))
		
		// Set appropriate Content-Type based on extension
		switch ext {
		case ".css":
			w.Header().Set("Content-Type", "text/css; charset=utf-8")
		case ".js":
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		case ".html":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		case ".json":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
		case ".png":
			w.Header().Set("Content-Type", "image/png")
		case ".jpg", ".jpeg":
			w.Header().Set("Content-Type", "image/jpeg")
		case ".gif":
			w.Header().Set("Content-Type", "image/gif")
		case ".svg":
			w.Header().Set("Content-Type", "image/svg+xml")
		case ".ico":
			w.Header().Set("Content-Type", "image/x-icon")
		case ".woff":
			w.Header().Set("Content-Type", "font/woff")
		case ".woff2":
			w.Header().Set("Content-Type", "font/woff2")
		case ".ttf":
			w.Header().Set("Content-Type", "font/ttf")
		case ".eot":
			w.Header().Set("Content-Type", "application/vnd.ms-fontobject")
		}
		
		// Add cache headers for static assets
		if ext != "" {
			w.Header().Set("Cache-Control", "public, max-age=3600")
		}
		
		next.ServeHTTP(w, r)
	})
}