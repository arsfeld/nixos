package tsnsrv

import (
	"errors"
	"fmt"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

// Config represents a multi-service configuration file
type Config struct {
	PrometheusAddr string          `yaml:"prometheusAddr,omitempty"`
	Services       []ServiceConfig `yaml:"services"`
}

// ServiceConfig represents configuration for a single service
type ServiceConfig struct {
	// Required fields
	Name     string `yaml:"name"`
	Upstream string `yaml:"upstream"`

	// Connection options
	UpstreamTCPAddr  string `yaml:"upstreamTCPAddr,omitempty"`
	UpstreamUnixAddr string `yaml:"upstreamUnixAddr,omitempty"`

	// Tailscale options
	Ephemeral  bool     `yaml:"ephemeral,omitempty"`
	Tags       []string `yaml:"tags,omitempty"`
	StateDir   string   `yaml:"stateDir,omitempty"`
	AuthkeyPath string  `yaml:"authkeyPath,omitempty"`

	// Network exposure
	Funnel       bool   `yaml:"funnel,omitempty"`
	FunnelOnly   bool   `yaml:"funnelOnly,omitempty"`
	ListenAddr   string `yaml:"listenAddr,omitempty"`
	ServePlaintext bool `yaml:"plaintext,omitempty"`

	// TLS options
	CertificateFile string `yaml:"certificateFile,omitempty"`
	KeyFile         string `yaml:"keyFile,omitempty"`

	// Proxy behavior
	RecommendedProxyHeaders bool              `yaml:"recommendedProxyHeaders,omitempty"`
	Prefixes                []string          `yaml:"prefixes,omitempty"`
	StripPrefix             bool              `yaml:"stripPrefix,omitempty"`
	UpstreamHeaders         map[string]string `yaml:"upstreamHeaders,omitempty"`

	// Security options
	InsecureHTTPS                bool `yaml:"insecureHTTPS,omitempty"`
	UpstreamAllowInsecureCiphers bool `yaml:"upstreamAllowInsecureCiphers,omitempty"`

	// WhoIs options
	SuppressWhois         bool          `yaml:"suppressWhois,omitempty"`
	WhoisTimeout          time.Duration `yaml:"whoisTimeout,omitempty"`
	SuppressTailnetDialer bool          `yaml:"suppressTailnetDialer,omitempty"`

	// Forward auth options
	AuthURL             string            `yaml:"authURL,omitempty"`
	AuthPath            string            `yaml:"authPath,omitempty"`
	AuthTimeout         time.Duration     `yaml:"authTimeout,omitempty"`
	AuthCopyHeaders     map[string]string `yaml:"authCopyHeaders,omitempty"`
	AuthInsecureHTTPS   bool              `yaml:"authInsecureHTTPS,omitempty"`
	AuthBypassForTailnet bool             `yaml:"authBypassForTailnet,omitempty"`

	// Timeouts and performance
	Timeout           time.Duration `yaml:"timeout,omitempty"`
	ReadHeaderTimeout time.Duration `yaml:"readHeaderTimeout,omitempty"`

	// Debugging
	TsnetVerbose bool `yaml:"tsnetVerbose,omitempty"`
}

var (
	errNoServices     = errors.New("configuration must define at least one service")
	errDuplicateName  = errors.New("duplicate service name")
)

// LoadConfig reads and parses a configuration file
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config file: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("validating config: %w", err)
	}

	return &cfg, nil
}

// Validate checks the configuration for errors
func (c *Config) Validate() error {
	if len(c.Services) == 0 {
		return errNoServices
	}

	// Check for duplicate names
	names := make(map[string]bool)
	var errs []error

	for i, svc := range c.Services {
		if svc.Name == "" {
			errs = append(errs, fmt.Errorf("service %d: %w", i, errNameRequired))
		} else if names[svc.Name] {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errDuplicateName))
		} else {
			names[svc.Name] = true
		}

		if svc.Upstream == "" {
			errs = append(errs, fmt.Errorf("service %s: upstream URL is required", svc.Name))
		}

		// Apply same validation rules as CLI
		if svc.ServePlaintext && svc.Funnel {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errNoPlaintextOnFunnel))
		}

		if (svc.CertificateFile != "" && svc.KeyFile == "") || (svc.CertificateFile == "" && svc.KeyFile != "") {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errBothCertificateFileKeyFile))
		}

		if svc.ServePlaintext && svc.CertificateFile != "" && svc.KeyFile != "" {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errNoPlaintextWithCustomCert))
		}

		if svc.UpstreamTCPAddr != "" && svc.UpstreamUnixAddr != "" {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errOnlyOneAddrType))
		}

		if !svc.Funnel && svc.FunnelOnly {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, errFunnelRequired))
		}

		// Validate tags format
		for _, tag := range svc.Tags {
			if len(tag) < 5 || tag[:4] != "tag:" {
				errs = append(errs, fmt.Errorf("service %s: tag %q: %w", svc.Name, tag, errTagFormat))
			}
		}
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	return nil
}

// ToTailnetSrv converts a ServiceConfig to TailnetSrv struct
func (sc *ServiceConfig) ToTailnetSrv() *TailnetSrv {
	ts := &TailnetSrv{
		Name:                         sc.Name,
		UpstreamTCPAddr:              sc.UpstreamTCPAddr,
		UpstreamUnixAddr:             sc.UpstreamUnixAddr,
		Ephemeral:                    sc.Ephemeral,
		Funnel:                       sc.Funnel,
		FunnelOnly:                   sc.FunnelOnly,
		ListenAddr:                   sc.ListenAddr,
		certificateFile:              sc.CertificateFile,
		keyFile:                      sc.KeyFile,
		ServePlaintext:               sc.ServePlaintext,
		StripPrefix:                  sc.StripPrefix,
		StateDir:                     sc.StateDir,
		AuthkeyPath:                  sc.AuthkeyPath,
		InsecureHTTPS:                sc.InsecureHTTPS,
		WhoisTimeout:                 sc.WhoisTimeout,
		SuppressWhois:                sc.SuppressWhois,
		SuppressTailnetDialer:        sc.SuppressTailnetDialer,
		ReadHeaderTimeout:            sc.ReadHeaderTimeout,
		TsnetVerbose:                 sc.TsnetVerbose,
		UpstreamAllowInsecureCiphers: sc.UpstreamAllowInsecureCiphers,
		AuthURL:                      sc.AuthURL,
		AuthPath:                     sc.AuthPath,
		AuthTimeout:                  sc.AuthTimeout,
		AuthInsecureHTTPS:            sc.AuthInsecureHTTPS,
		AuthBypassForTailnet:         sc.AuthBypassForTailnet,
		Timeout:                      sc.Timeout,
	}

	// Set defaults
	if ts.ListenAddr == "" {
		ts.ListenAddr = ":443"
	}
	if ts.AuthPath == "" && ts.AuthURL != "" {
		ts.AuthPath = "/api/authz/forward-auth"
	}
	if ts.AuthTimeout == 0 && ts.AuthURL != "" {
		ts.AuthTimeout = 5 * time.Second
	}
	if ts.WhoisTimeout == 0 && !ts.SuppressWhois {
		ts.WhoisTimeout = 1 * time.Second
	}
	if ts.Timeout == 0 {
		ts.Timeout = 1 * time.Minute
	}
	ts.RecommendedProxyHeaders = sc.RecommendedProxyHeaders
	// Default to true if not explicitly set to false
	if sc.RecommendedProxyHeaders {
		ts.RecommendedProxyHeaders = true
	}
	ts.StripPrefix = sc.StripPrefix
	// Default to true if not explicitly set to false
	if sc.StripPrefix {
		ts.StripPrefix = true
	}

	// Convert tags
	for _, tag := range sc.Tags {
		ts.Tags = append(ts.Tags, tag)
	}

	// Convert prefixes
	for _, prefix := range sc.Prefixes {
		ts.AllowedPrefixes.Set(prefix)
	}

	// Convert upstream headers
	if sc.UpstreamHeaders != nil {
		ts.UpstreamHeaders = make(headers)
		for name, value := range sc.UpstreamHeaders {
			ts.UpstreamHeaders.Set(fmt.Sprintf("%s: %s", name, value))
		}
	}

	// Convert auth copy headers
	if sc.AuthCopyHeaders != nil {
		ts.AuthCopyHeaders = make(headers)
		for name, value := range sc.AuthCopyHeaders {
			ts.AuthCopyHeaders.Set(fmt.Sprintf("%s: %s", name, value))
		}
	}

	return ts
}
