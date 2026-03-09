package tsnsrv

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"golang.org/x/exp/slog"
	"tailscale.com/client/tailscale/apitype"
)

// WhoIsClient is an interface for the WhoIs functionality to allow testing
type WhoIsClient interface {
	WhoIs(ctx context.Context, addr string) (*apitype.WhoIsResponse, error)
}

type contextKey struct{}

var proxyContextKey = contextKey{}

var (
	requestDurations = promauto.NewSummaryVec(prometheus.SummaryOpts{
		Name:       "tsnsrv_request_duration_ns",
		Help:       "Duration of requests served",
		Objectives: map[float64]float64{0.5: 0.05, 0.9: 0.01, 0.99: 0.001},
	}, []string{"service_name"})
	responseStatusClasses = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tsnsrv_response_status_classes",
		Help: "Responses by status code class (1xx, etc)",
	}, []string{"service_name", "status_code_class"})
	proxyErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tsnsrv_proxy_errors",
		Help: "Number of errors encountered proxying requests",
	}, []string{"service_name"})
	authRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tsnsrv_auth_requests_total",
		Help: "Total number of authorization requests",
	}, []string{"service_name", "status"})
	authDurations = promauto.NewSummaryVec(prometheus.SummaryOpts{
		Name:       "tsnsrv_auth_duration_ns",
		Help:       "Duration of authorization requests",
		Objectives: map[float64]float64{0.5: 0.05, 0.9: 0.01, 0.99: 0.001},
	}, []string{"service_name"})
)

type proxyContext struct {
	start        time.Time
	who          *apitype.WhoIsResponse
	originalURL  *url.URL
	rewrittenURL *url.URL
	serviceName  string
}

func (c *proxyContext) observeResponse(res *http.Response) {
	elapsed := time.Since(c.start)
	requestDurations.With(prometheus.Labels{"service_name": c.serviceName}).Observe(float64(elapsed))

	statusClass := fmt.Sprintf("%dxx", res.StatusCode/100)
	responseStatusClasses.With(prometheus.Labels{
		"service_name":      c.serviceName,
		"status_code_class": statusClass,
	}).Inc()

	login := ""
	node := ""
	if c.who != nil {
		login = c.who.UserProfile.LoginName
		node = c.who.Node.Name
	}

	slog.Info("served",
		"service", c.serviceName,
		"original", c.originalURL,
		"rewritten", c.rewrittenURL,
		"origin_login", login,
		"origin_node", node,
		"duration", elapsed,
		"http_status", res.StatusCode,
	)
}

func (s *ValidTailnetSrv) modifyResponse(res *http.Response) error {
	p := res.Request.Context().Value(proxyContextKey).(*proxyContext)
	if p != nil {
		p.observeResponse(res)
	}
	return nil
}

func (s *ValidTailnetSrv) errorHandler(rw http.ResponseWriter, _ *http.Request, err error) {
	slog.Warn("proxy error",
		"service", s.Name,
		"error", err,
	)
	proxyErrors.With(prometheus.Labels{"service_name": s.Name}).Inc()
	rw.WriteHeader(http.StatusBadGateway)
}

func (s *ValidTailnetSrv) rewrite(r *httputil.ProxyRequest) {
	r.SetURL(s.DestURL)
	if r.In.URL.Path == "" {
		r.Out.URL.Path = s.DestURL.Path
	}

	r.SetXForwarded()
	if s.RecommendedProxyHeaders {
		if r.In.TLS == nil {
			r.Out.Header.Set("X-Scheme", "http")
		} else {
			r.Out.Header.Set("X-Scheme", "https")
		}
		r.Out.Host = r.In.Host
		remoteIP, _, err := net.SplitHostPort(r.In.RemoteAddr)
		if err == nil {
			r.Out.Header.Set("X-Real-Ip", remoteIP)
		}
		hostOnly, port, err := net.SplitHostPort(r.In.Host)
		if err != nil {
			r.Out.Header.Set("X-Forwarded-Server", r.In.Host)
		} else {
			r.Out.Header.Set("X-Forwarded-Server", hostOnly)
			r.Out.Header.Set("X-Forwarded-Port", port)
		}
	}

	for h, vals := range s.UpstreamHeaders {
		r.Out.Header[h] = vals
	}

	who := s.setWhoisHeaders(r)
	r.Out = r.Out.WithContext(context.WithValue(r.Out.Context(), proxyContextKey, &proxyContext{
		start:        time.Now(),
		originalURL:  r.In.URL,
		rewrittenURL: r.Out.URL,
		who:          who,
		serviceName:  s.Name,
	}))
}

// Clean up and set user/node identity headers:.
func (s *ValidTailnetSrv) setWhoisHeaders(r *httputil.ProxyRequest) *apitype.WhoIsResponse {
	// First, clean out any input we received that looks like TS setting headers:
	for k := range r.Out.Header {
		if strings.HasPrefix(k, "X-Tailscale-") {
			r.Out.Header.Del(k)
		}
	}
	if s.SuppressWhois || s.client == nil {
		return nil
	}

	ctx := r.In.Context()
	if s.WhoisTimeout > 0 {
		var cancel func()
		ctx, cancel = context.WithTimeout(ctx, s.WhoisTimeout)
		defer cancel()
	}
	who, err := s.client.WhoIs(ctx, r.In.RemoteAddr)
	if err != nil {
		slog.Warn("could not look up requestor identity",
			"error", err,
			"request", r.In,
		)
		return nil
	}
	h := r.Out.Header
	h.Set("X-Tailscale-User", who.UserProfile.ID.String())
	login := who.UserProfile.LoginName
	h.Set("X-Tailscale-User-LoginName", login)
	ll, ld, splitable := strings.Cut(login, "@")
	if splitable {
		h.Set("X-Tailscale-User-LoginName-Localpart", ll)
		h.Set("X-Tailscale-User-LoginName-Domain", ld)
	}
	h.Set("X-Tailscale-User-DisplayName", who.UserProfile.DisplayName)
	if who.UserProfile.ProfilePicURL != "" {
		h.Set("X-Tailscale-User-ProfilePicURL", who.UserProfile.ProfilePicURL)
	}
	if len(who.CapMap) > 0 {
		var caps []string
		for cap := range who.CapMap {
			caps = append(caps, string(cap))
		}
		h.Set("X-Tailscale-Caps", strings.Join(caps, ", "))
	}

	h.Set("X-Tailscale-Node", who.Node.ID.String())
	h.Set("X-Tailscale-Node-Name", who.Node.ComputedName)
	if len(who.Node.CapMap) > 0 {
		var capabilities []string
		for cap := range who.Node.CapMap {
			capabilities = append(capabilities, string(cap))
		}
		h.Set("X-Tailscale-Node-Caps", strings.Join(capabilities, ", "))
	}
	if len(who.Node.Tags) > 0 {
		h.Set("X-Tailscale-Node-Tags", strings.Join(who.Node.Tags, ", "))
	}
	return who
}

// authMiddleware handles forward authentication by making a request to the auth service
func (s *ValidTailnetSrv) authMiddleware(next http.Handler) http.Handler {
	if s.AuthURL == "" {
		return next
	}

	authURL, err := url.Parse(s.AuthURL)
	if err != nil {
		slog.Error("invalid auth URL", "url", s.AuthURL, "error", err)
		return next
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}
	if s.AuthInsecureHTTPS {
		transport.TLSClientConfig.InsecureSkipVerify = true
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   s.AuthTimeout,
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check if we should bypass auth for Tailscale users
		if s.AuthBypassForTailnet && !s.SuppressWhois && s.client != nil {
			ctx := r.Context()
			if s.WhoisTimeout > 0 {
				var cancel func()
				ctx, cancel = context.WithTimeout(ctx, s.WhoisTimeout)
				defer cancel()
			}
			who, err := s.client.WhoIs(ctx, r.RemoteAddr)
			if err == nil && who.UserProfile.ID != 0 && who.UserProfile.LoginName != "tagged-devices" {
				// Request is from authenticated Tailscale user, bypass auth
				slog.Info("auth bypassed",
					"service", s.Name,
					"user", who.UserProfile.LoginName,
					"remote_addr", r.RemoteAddr,
					"url", r.URL,
					"reason", "tailscale_user",
				)
				next.ServeHTTP(w, r)
				return
			}
		}

		start := time.Now()

		// Create auth request
		authReq := &http.Request{
			Method: "GET",
			URL: &url.URL{
				Scheme:   authURL.Scheme,
				Host:     authURL.Host,
				Path:     s.AuthPath,
				RawQuery: r.URL.RawQuery,
			},
			Header: make(http.Header),
		}

		// Copy relevant headers from original request
		for name, values := range r.Header {
			if name == "Authorization" || strings.HasPrefix(name, "X-") || name == "Cookie" || name == "User-Agent" {
				authReq.Header[name] = values
			}
		}

		// Set additional headers for auth service
		authReq.Header.Set("X-Forwarded-Method", r.Method)
		authReq.Header.Set("X-Forwarded-Uri", r.URL.String())
		if r.Host != "" {
			authReq.Header.Set("X-Forwarded-Host", r.Host)
		}
		if r.TLS != nil {
			authReq.Header.Set("X-Forwarded-Proto", "https")
		} else {
			authReq.Header.Set("X-Forwarded-Proto", "http")
		}

		// Make auth request
		authResp, err := client.Do(authReq)
		if err != nil {
			elapsed := time.Since(start)
			authDurations.With(prometheus.Labels{"service_name": s.Name}).Observe(float64(elapsed))
			authRequests.With(prometheus.Labels{
				"service_name": s.Name,
				"status":       "error",
			}).Inc()
			slog.Warn("auth request failed", "service", s.Name, "error", err, "url", authReq.URL)
			http.Error(w, "Authorization service unavailable", http.StatusBadGateway)
			return
		}
		defer authResp.Body.Close()

		elapsed := time.Since(start)
		authDurations.With(prometheus.Labels{"service_name": s.Name}).Observe(float64(elapsed))
		statusClass := fmt.Sprintf("%dxx", authResp.StatusCode/100)
		authRequests.With(prometheus.Labels{
			"service_name": s.Name,
			"status":       statusClass,
		}).Inc()

		// If auth service returns 2xx, continue with the request
		if authResp.StatusCode >= 200 && authResp.StatusCode < 300 {
			// Copy configured headers from auth response to original request
			var copiedHeaders []string
			for headerName := range s.AuthCopyHeaders {
				if value := authResp.Header.Get(headerName); value != "" {
					r.Header.Set(headerName, value)
					copiedHeaders = append(copiedHeaders, headerName)
				}
			}

			slog.Info("auth granted",
				"service", s.Name,
				"status", authResp.StatusCode,
				"duration", elapsed,
				"remote_addr", r.RemoteAddr,
				"url", r.URL,
				"copied_headers", copiedHeaders,
			)
			next.ServeHTTP(w, r)
			return
		}

		// For non-2xx responses, return the auth service response to client
		slog.Info("auth denied",
			"service", s.Name,
			"status", authResp.StatusCode,
			"remote_addr", r.RemoteAddr,
			"duration", elapsed,
			"url", r.URL,
		)

		// Copy headers from auth response
		for name, values := range authResp.Header {
			w.Header()[name] = values
		}
		w.WriteHeader(authResp.StatusCode)

		// Copy body from auth response
		io.Copy(w, authResp.Body)
	})
}

// matchPrefixes acts like the http.StripPrefix middleware, except
// that it checks against several allowed prefixes (an empty list
// means that all prefixes are allowed); if no prefixes match, it
// returns 404.
func matchPrefixes(prefixes []prefix, strip bool, forFunnel bool, handler http.Handler) http.Handler {
	if len(prefixes) == 0 {
		return handler
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, prefix := range prefixes {
			if ok, stripData := prefix.matches(r.URL, forFunnel); ok {
				r2 := new(http.Request)
				*r2 = *r
				if strip {
					r2.URL = new(url.URL)
					*r2.URL = *r.URL
					r2.URL.Path = stripData.path
					r2.URL.RawPath = stripData.rawPath
				}
				handler.ServeHTTP(w, r2)
				return
			}
		}
		slog.WarnCtx(r.Context(), "URL prefix not allowed",
			"url", r.URL,
			"prefixes", prefixes,
			"forFunnel", forFunnel,
		)
		http.NotFound(w, r)
	})
}

func (s *ValidTailnetSrv) mux(transport http.RoundTripper, forFunnel bool) http.Handler {
	proxy := &httputil.ReverseProxy{
		Rewrite:        s.rewrite,
		ModifyResponse: s.modifyResponse,
		ErrorHandler:   s.errorHandler,
		Transport:      transport,
	}
	handler := matchPrefixes(s.AllowedPrefixes, s.StripPrefix, forFunnel, proxy)
	authHandler := s.authMiddleware(handler)
	mux := http.NewServeMux()
	mux.Handle("/", authHandler)
	return mux
}
