package tsnsrv

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

// mockLocalClient is a mock implementation of the tailscale.LocalClient
type mockLocalClient struct {
	whoIsFunc func(ctx context.Context, addr string) (*apitype.WhoIsResponse, error)
}

func (m *mockLocalClient) WhoIs(ctx context.Context, addr string) (*apitype.WhoIsResponse, error) {
	if m.whoIsFunc != nil {
		return m.whoIsFunc(ctx, addr)
	}
	return nil, nil
}

func TestAuthMiddleware(t *testing.T) {
	// Test case 1: No auth URL configured - should pass through
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL: "",
		},
	}

	// Create a test handler that sets a header to verify it was called
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Test-Called", "true")
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Header().Get("Test-Called") != "true" {
		t.Error("Expected middleware to pass through when no auth URL configured")
	}
}

func TestAuthMiddlewareWithAuthService(t *testing.T) {
	// Create a mock auth service
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the auth request has correct headers
		if r.Header.Get("X-Forwarded-Method") != "GET" {
			t.Error("Expected X-Forwarded-Method header")
		}
		if r.Header.Get("X-Forwarded-Proto") == "" {
			t.Error("Expected X-Forwarded-Proto header")
		}

		// Return 200 with a test header
		w.Header().Set("Remote-User", "testuser")
		w.WriteHeader(http.StatusOK)
	}))
	defer authServer.Close()

	// Configure auth middleware
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 5 * time.Second,
			AuthCopyHeaders: headers{
				"Remote-User": []string{""},
			},
		},
	}

	// Create a test handler
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify the copied header is present
		if r.Header.Get("Remote-User") != "testuser" {
			t.Errorf("Expected Remote-User header to be 'testuser', got '%s'", r.Header.Get("Remote-User"))
		}
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status OK, got %d", w.Code)
	}
}

func TestAuthMiddlewareUnauthorized(t *testing.T) {
	// Create a mock auth service that returns 401
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "/login")
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte("Unauthorized"))
	}))
	defer authServer.Close()

	// Configure auth middleware
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 5 * time.Second,
		},
	}

	// Create a test handler (should not be called)
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Test handler should not be called when auth fails")
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status Unauthorized, got %d", w.Code)
	}
	if w.Header().Get("Location") != "/login" {
		t.Error("Expected Location header to be copied from auth response")
	}
}

func TestAuthMiddlewareBypassForTailnet(t *testing.T) {
	// Create a mock auth service that should NOT be called
	authCallCount := 0
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authCallCount++
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer authServer.Close()

	// Create a mock Tailscale client that returns a valid user
	mockClient := &mockLocalClient{
		whoIsFunc: func(ctx context.Context, addr string) (*apitype.WhoIsResponse, error) {
			return &apitype.WhoIsResponse{
				UserProfile: &tailcfg.UserProfile{
					ID:          tailcfg.UserID(12345),
					LoginName:   "user@example.com",
					DisplayName: "Test User",
				},
			}, nil
		},
	}

	// Configure auth middleware with bypass enabled
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:              authServer.URL,
			AuthPath:             "/api/authz/forward-auth",
			AuthTimeout:          5 * time.Second,
			AuthBypassForTailnet: true,
			SuppressWhois:        false,
		},
		client: mockClient,
	}

	// Create a test handler
	handlerCalled := false
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handlerCalled = true
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	req.RemoteAddr = "100.100.100.100:12345"
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if !handlerCalled {
		t.Error("Expected handler to be called when bypass is enabled for Tailscale user")
	}
	if authCallCount > 0 {
		t.Error("Expected auth service not to be called when bypass is enabled for Tailscale user")
	}
	if w.Code != http.StatusOK {
		t.Errorf("Expected status OK, got %d", w.Code)
	}
}

func TestAuthMiddlewareBypassDisabled(t *testing.T) {
	// Create a mock auth service that should be called
	authCalled := false
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authCalled = true
		w.WriteHeader(http.StatusOK)
	}))
	defer authServer.Close()

	// Create a mock Tailscale client that returns a valid user
	mockClient := &mockLocalClient{
		whoIsFunc: func(ctx context.Context, addr string) (*apitype.WhoIsResponse, error) {
			return &apitype.WhoIsResponse{
				UserProfile: &tailcfg.UserProfile{
					ID:          tailcfg.UserID(12345),
					LoginName:   "user@example.com",
					DisplayName: "Test User",
				},
			}, nil
		},
	}

	// Configure auth middleware with bypass disabled
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:              authServer.URL,
			AuthPath:             "/api/authz/forward-auth",
			AuthTimeout:          5 * time.Second,
			AuthBypassForTailnet: false, // Bypass disabled
			SuppressWhois:        false,
		},
		client: mockClient,
	}

	// Create a test handler
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	req.RemoteAddr = "100.100.100.100:12345"
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if !authCalled {
		t.Error("Expected auth service to be called when bypass is disabled")
	}
}

func TestAuthMiddlewareBypassNoTailscaleUser(t *testing.T) {
	// Create a mock auth service that should be called
	authCalled := false
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authCalled = true
		w.WriteHeader(http.StatusOK)
	}))
	defer authServer.Close()

	// Create a mock Tailscale client that returns no user (not from Tailscale)
	mockClient := &mockLocalClient{
		whoIsFunc: func(ctx context.Context, addr string) (*apitype.WhoIsResponse, error) {
			return &apitype.WhoIsResponse{
				UserProfile: &tailcfg.UserProfile{
					// Empty ID means not authenticated
					ID: tailcfg.UserID(0),
				},
			}, nil
		},
	}

	// Configure auth middleware with bypass enabled
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:              authServer.URL,
			AuthPath:             "/api/authz/forward-auth",
			AuthTimeout:          5 * time.Second,
			AuthBypassForTailnet: true,
			SuppressWhois:        false,
		},
		client: mockClient,
	}

	// Create a test handler
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	req.RemoteAddr = "192.168.1.1:12345"
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	if !authCalled {
		t.Error("Expected auth service to be called when request is not from Tailscale network")
	}
}

func TestAuthMiddlewareTimeout(t *testing.T) {
	// Create a mock auth service that times out
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Simulate a slow auth service
		time.Sleep(2 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer authServer.Close()

	// Configure auth middleware with a very short timeout
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 10 * time.Millisecond, // Very short timeout
		},
	}

	// Create a test handler (should not be called on timeout)
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Test handler should not be called when auth times out")
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	// Should return 502 Bad Gateway when auth service is unavailable
	if w.Code != http.StatusBadGateway {
		t.Errorf("Expected status Bad Gateway on timeout, got %d", w.Code)
	}
}

func TestAuthMiddlewareConnectionFailure(t *testing.T) {
	// Configure auth middleware with an unreachable host
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     "http://192.0.2.1:9999", // TEST-NET-1, guaranteed to not respond
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 100 * time.Millisecond,
		},
	}

	// Create a test handler (should not be called on connection failure)
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Test handler should not be called when auth service is unreachable")
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	// Should return 502 Bad Gateway when auth service is unavailable
	if w.Code != http.StatusBadGateway {
		t.Errorf("Expected status Bad Gateway on connection failure, got %d", w.Code)
	}
}

func TestAuthMiddleware3xxResponse(t *testing.T) {
	// Create a mock auth service that returns a 3xx (non-2xx) response
	// The HTTP client will try to follow redirects automatically, but if
	// the redirect fails or isn't followed for any reason, we should pass
	// through the response to the client
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Return 307 with a body - auth service might use this to indicate
		// the request needs to go through additional authentication
		w.Header().Set("WWW-Authenticate", "Bearer realm=\"example\"")
		w.WriteHeader(http.StatusTemporaryRedirect)
		w.Write([]byte("Additional authentication required"))
	}))
	defer authServer.Close()

	// Configure auth middleware
	srv := &ValidTailnetSrv{
		TailnetSrv: TailnetSrv{
			AuthURL:     authServer.URL,
			AuthPath:    "/api/authz/forward-auth",
			AuthTimeout: 5 * time.Second,
		},
	}

	// Create a test handler (should not be called on non-2xx response)
	testHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("Test handler should not be called when auth returns non-2xx")
	})

	middleware := srv.authMiddleware(testHandler)
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	middleware.ServeHTTP(w, req)

	// Should pass through the non-2xx response
	if w.Code != http.StatusTemporaryRedirect {
		t.Errorf("Expected status Temporary Redirect, got %d", w.Code)
	}
	if w.Header().Get("WWW-Authenticate") == "" {
		t.Error("Expected WWW-Authenticate header to be passed through from auth response")
	}
}