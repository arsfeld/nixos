package tsnsrv

import (
	"cmp"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/pprof"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"time"

	"github.com/peterbourgon/ff/v3/ffcli"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/exp/slog"
	"golang.org/x/oauth2/clientcredentials"
	"tailscale.com/client/tailscale/v2"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

type prefixMatch int

const (
	matchEither prefixMatch = iota
	matchFunnelOnly
	matchTsnetOnly
)

type prefix struct {
	path    string
	matchIf prefixMatch
}

type strippedPrefixes struct {
	path    string
	rawPath string
}

// matches returns whether an allowlist entry matches a request's URL and circumstance.
func (pref *prefix) matches(reqURL *url.URL, isFunnel bool) (bool, strippedPrefixes) {
	if isFunnel && pref.matchIf == matchTsnetOnly {
		return false, strippedPrefixes{}
	}
	if !isFunnel && pref.matchIf == matchFunnelOnly {
		return false, strippedPrefixes{}
	}

	p := strings.TrimPrefix(reqURL.Path, pref.path)
	rp := strings.TrimPrefix(reqURL.RawPath, pref.path)
	return len(p) < len(reqURL.Path) && (reqURL.RawPath == "" || len(rp) < len(reqURL.RawPath)), strippedPrefixes{p, rp}
}

type prefixes []prefix

func (p *prefixes) String() string {
	seq := func(yield func(string) bool) {
		for _, pref := range *p {
			var p string
			switch pref.matchIf {
			case matchEither:
				p = pref.path
			case matchFunnelOnly:
				p = fmt.Sprintf("funnel:%s", pref.path)
			case matchTsnetOnly:
				p = fmt.Sprintf("tailnet:%s", pref.path)
			}
			if !yield(p) {
				return
			}
		}
	}
	serialized := slices.Collect(seq)
	return strings.Join(serialized, ", ")
}

func (p *prefixes) Set(value string) error {
	var pref prefix
	switch {
	case strings.HasPrefix(value, "tailnet:"):
		pref.matchIf = matchTsnetOnly
		pref.path = strings.TrimPrefix(value, "tailnet:")
	case strings.HasPrefix(value, "funnel:"):
		pref.matchIf = matchFunnelOnly
		pref.path = strings.TrimPrefix(value, "funnel:")
	default:
		pref.path = value
	}

	*p = append(*p, pref)
	return nil
}

type headers http.Header

func (h *headers) String() string {
	var coll []string
	for name, vals := range *h {
		for _, val := range vals {
			coll = append(coll, fmt.Sprintf("%s: %s", name, val))
		}
	}
	return strings.Join(coll, ", ")
}

var errHeaderFormat = errors.New("header format must be 'Header-Name: value'")

func (h *headers) Set(value string) error {
	name, val, ok := strings.Cut(value, ": ")
	if !ok {
		return fmt.Errorf("%w: Invalid header format %#v", errHeaderFormat, value)
	}
	if *h == nil {
		*h = headers{}
	}
	http.Header((*h)).Add(name, val)
	return nil
}

type tags []string

func (t *tags) String() string {
	return strings.Join(*t, ", ")
}

var errTagFormat = errors.New("tags must start with 'tag:'")

func (t *tags) Set(value string) error {
	if !strings.HasPrefix(value, "tag:") {
		return errTagFormat
	}
	*t = append(*t, value)
	return nil
}

type serviceFlags []ServiceConfig

func (s *serviceFlags) String() string {
	if len(*s) == 0 {
		return ""
	}
	var parts []string
	for _, svc := range *s {
		parts = append(parts, fmt.Sprintf("%s->%s", svc.Name, svc.Upstream))
	}
	return strings.Join(parts, "; ")
}

var errServiceFlagFormat = errors.New("service flag format must be key=value pairs separated by commas")

func (s *serviceFlags) Set(value string) error {
	svc := ServiceConfig{
		// Set defaults
		ListenAddr:              ":443",
		RecommendedProxyHeaders: true,
		StripPrefix:             true,
		AuthPath:                "/api/authz/forward-auth",
		AuthTimeout:             5 * time.Second,
		WhoisTimeout:            1 * time.Second,
		Timeout:                 1 * time.Minute,
	}

	// Parse key=value pairs separated by commas
	pairs := strings.Split(value, ",")
	for _, pair := range pairs {
		key, val, ok := strings.Cut(strings.TrimSpace(pair), "=")
		if !ok {
			return fmt.Errorf("%w: invalid pair %q", errServiceFlagFormat, pair)
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)

		if err := s.setServiceField(&svc, key, val); err != nil {
			return fmt.Errorf("setting %s: %w", key, err)
		}
	}

	// Validate required fields
	if svc.Name == "" {
		return fmt.Errorf("service definition: %w", errNameRequired)
	}
	if svc.Upstream == "" {
		return errors.New("service definition: upstream is required")
	}

	*s = append(*s, svc)
	return nil
}

func (s *serviceFlags) setServiceField(svc *ServiceConfig, key, value string) error {
	switch key {
	// Required fields
	case "name":
		svc.Name = value
	case "upstream":
		svc.Upstream = value

	// Connection options
	case "upstreamTCPAddr":
		svc.UpstreamTCPAddr = value
	case "upstreamUnixAddr":
		svc.UpstreamUnixAddr = value

	// Tailscale options
	case "ephemeral":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.Ephemeral = v
	case "tag":
		if !strings.HasPrefix(value, "tag:") {
			return errTagFormat
		}
		svc.Tags = append(svc.Tags, value)
	case "stateDir":
		svc.StateDir = value
	case "authkeyPath":
		svc.AuthkeyPath = value

	// Network exposure
	case "funnel":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.Funnel = v
	case "funnelOnly":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.FunnelOnly = v
	case "listenAddr":
		svc.ListenAddr = value
	case "plaintext":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.ServePlaintext = v

	// TLS options
	case "certificateFile":
		svc.CertificateFile = value
	case "keyFile":
		svc.KeyFile = value

	// Proxy behavior
	case "recommendedProxyHeaders":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.RecommendedProxyHeaders = v
	case "prefix":
		svc.Prefixes = append(svc.Prefixes, value)
	case "stripPrefix":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.StripPrefix = v
	case "upstreamHeader":
		if svc.UpstreamHeaders == nil {
			svc.UpstreamHeaders = make(map[string]string)
		}
		name, val, ok := strings.Cut(value, ":")
		if !ok {
			return fmt.Errorf("header format must be 'Name:Value', got %q", value)
		}
		svc.UpstreamHeaders[strings.TrimSpace(name)] = strings.TrimSpace(val)

	// Security options
	case "insecureHTTPS":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.InsecureHTTPS = v
	case "upstreamAllowInsecureCiphers":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.UpstreamAllowInsecureCiphers = v

	// WhoIs options
	case "suppressWhois":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.SuppressWhois = v
	case "whoisTimeout":
		d, err := time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("parsing duration: %w", err)
		}
		svc.WhoisTimeout = d
	case "suppressTailnetDialer":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.SuppressTailnetDialer = v

	// Forward auth options
	case "authURL":
		svc.AuthURL = value
	case "authPath":
		svc.AuthPath = value
	case "authTimeout":
		d, err := time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("parsing duration: %w", err)
		}
		svc.AuthTimeout = d
	case "authCopyHeader":
		if svc.AuthCopyHeaders == nil {
			svc.AuthCopyHeaders = make(map[string]string)
		}
		name, val, ok := strings.Cut(value, ":")
		if !ok {
			return fmt.Errorf("header format must be 'Name:Value', got %q", value)
		}
		svc.AuthCopyHeaders[strings.TrimSpace(name)] = strings.TrimSpace(val)
	case "authInsecureHTTPS":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.AuthInsecureHTTPS = v
	case "authBypassForTailnet":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.AuthBypassForTailnet = v

	// Timeouts and performance
	case "timeout":
		d, err := time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("parsing duration: %w", err)
		}
		svc.Timeout = d
	case "readHeaderTimeout":
		d, err := time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("parsing duration: %w", err)
		}
		svc.ReadHeaderTimeout = d

	// Debugging
	case "tsnetVerbose":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		svc.TsnetVerbose = v

	default:
		return fmt.Errorf("unknown service configuration key: %q", key)
	}

	return nil
}

func parseBool(s string) (bool, error) {
	switch strings.ToLower(s) {
	case "true", "yes", "1", "y":
		return true, nil
	case "false", "no", "0", "n":
		return false, nil
	default:
		return false, fmt.Errorf("invalid boolean value: %q", s)
	}
}

type TailnetSrv struct {
	UpstreamTCPAddr, UpstreamUnixAddr string
	Ephemeral                         bool
	Funnel, FunnelOnly                bool
	ListenAddr                        string
	certificateFile                   string
	keyFile                           string
	Name                              string
	RecommendedProxyHeaders           bool
	ServePlaintext                    bool
	Timeout                           time.Duration
	AllowedPrefixes                   prefixes
	StripPrefix                       bool
	StateDir                          string
	AuthkeyPath                       string
	Tags                              tags
	InsecureHTTPS                     bool
	WhoisTimeout                      time.Duration
	SuppressWhois                     bool
	UpstreamHeaders                   headers
	SuppressTailnetDialer             bool
	ReadHeaderTimeout                 time.Duration
	TsnetVerbose                      bool
	UpstreamAllowInsecureCiphers      bool
	AuthURL                           string
	AuthPath                          string
	AuthTimeout                       time.Duration
	AuthCopyHeaders                   headers
	AuthInsecureHTTPS                 bool
	AuthBypassForTailnet              bool
}

// ValidTailnetSrv is a TailnetSrv that has been constructed from validated CLI arguments.
//
// Use TailnetSrvFromArgs to get an instance of it.
type ValidTailnetSrv struct {
	TailnetSrv
	DestURL *url.URL
	client  WhoIsClient
}

// TailnetSrvFromArgs constructs a validated tailnet service from commandline arguments.
func TailnetSrvFromArgs(args []string) (*ValidTailnetSrv, string, *ffcli.Command, error) {
	services, prometheusAddr, cmd, err := TailnetSrvsFromArgs(args)
	if err != nil {
		return nil, "", cmd, err
	}
	if len(services) != 1 {
		return nil, "", cmd, fmt.Errorf("expected single service, got %d", len(services))
	}
	return services[0], prometheusAddr, cmd, nil
}

var errConfigAndCLI = errors.New("cannot use -config with other CLI flags; use either config file or CLI mode")

// TailnetSrvsFromArgs constructs validated tailnet services from commandline arguments.
// Supports three modes:
// 1. Single-service CLI mode (legacy): -name <name> <url>
// 2. Multi-service config file mode: -config <file>
// 3. Multi-service CLI mode: -service "key=val,..." [-service "key=val,..."]
// Returns the services, the process-level prometheusAddr, the command, and any error.
func TailnetSrvsFromArgs(args []string) ([]*ValidTailnetSrv, string, *ffcli.Command, error) {
	s := &TailnetSrv{}
	var configPath string
	var services serviceFlags
	var prometheusAddr string

	fs := flag.NewFlagSet("tsnsrv", flag.ExitOnError)
	fs.StringVar(&configPath, "config", "", "Path to configuration file for multi-service mode")
	fs.Var(&services, "service", "Service definition as key=value pairs (repeatable for multiple services)")
	fs.StringVar(&s.UpstreamTCPAddr, "upstreamTCPAddr", "", "Proxy to an HTTP service listening on this TCP address")
	fs.StringVar(&s.UpstreamUnixAddr, "upstreamUnixAddr", "", "Proxy to an HTTP service listening on this UNIX domain socket address")
	fs.BoolVar(&s.Ephemeral, "ephemeral", false, "Declare this service ephemeral")
	fs.BoolVar(&s.Funnel, "funnel", false, "Expose a funnel service.")
	fs.BoolVar(&s.FunnelOnly, "funnelOnly", false, "Expose a funnel service only (not exposed on the tailnet).")
	fs.StringVar(&s.ListenAddr, "listenAddr", ":443", "Address to listen on; note only :443, :8443 and :10000 are supported with -funnel.")
	fs.StringVar(&s.certificateFile, "certificateFile", "", "Custom certificate file to use for TLS listening instead of Tailscale's builtin way.")
	fs.StringVar(&s.keyFile, "keyFile", "", "Custom key file to use for TLS listening instead of Tailscale's builtin way.")
	fs.StringVar(&s.Name, "name", "", "Name of this service")
	fs.BoolVar(&s.RecommendedProxyHeaders, "recommendedProxyHeaders", true, "Set Host, X-Scheme, X-Real-Ip, X-Forwarded-{Proto,Server,Port} headers.")
	fs.BoolVar(&s.ServePlaintext, "plaintext", false, "Serve plaintext HTTP without TLS")
	fs.DurationVar(&s.Timeout, "timeout", 1*time.Minute, "Timeout connecting to the tailnet")
	fs.Var(&s.AllowedPrefixes, "prefix", "Allowed URL prefixes; if none is set, all prefixes are allowed")
	fs.BoolVar(&s.StripPrefix, "stripPrefix", true, "Strip prefixes that matched; best set to false if allowing multiple prefixes")
	fs.StringVar(&s.StateDir, "stateDir", os.Getenv("TS_STATE_DIR"), "Directory containing the persistent tailscale status files. Can also be set by $TS_STATE_DIR; this option takes precedence.")
	fs.StringVar(&s.AuthkeyPath, "authkeyPath", "", "File containing a tailscale auth key. Key is assumed to be in $TS_AUTHKEY in absence of this option.")
	fs.Var(&s.Tags, "tag", "Tags to advertise to tailscale. Mandatory if using OAuth clients.")
	fs.BoolVar(&s.InsecureHTTPS, "insecureHTTPS", false, "Disable TLS certificate validation on upstream")
	fs.DurationVar(&s.WhoisTimeout, "whoisTimeout", 1*time.Second, "Maximum amount of time to spend looking up client identities")
	fs.BoolVar(&s.SuppressWhois, "suppressWhois", false, "Do not set X-Tailscale-User-* headers in upstream requests")
	fs.StringVar(&prometheusAddr, "prometheusAddr", ":9099", "Serve prometheus metrics from this address. Empty string to disable.")
	fs.Var(&s.UpstreamHeaders, "upstreamHeader", "Additional headers (separated by ': ') on requests to upstream.")
	fs.BoolVar(&s.SuppressTailnetDialer, "suppressTailnetDialer", false, "Whether to use the stdlib net.Dialer instead of a tailnet-enabled one")
	fs.DurationVar(&s.ReadHeaderTimeout, "readHeaderTimeout", 0, "Amount of time to allow for reading HTTP request headers. 0 will disable the timeout but expose the service to the slowloris attack.")
	fs.BoolVar(&s.TsnetVerbose, "tsnetVerbose", false, "Whether to output tsnet logs.")
	fs.BoolVar(&s.UpstreamAllowInsecureCiphers, "upstreamAllowInsecureCiphers", false, "Don't require Perfect Forward Secrecy from the upstream https server.")
	fs.StringVar(&s.AuthURL, "authURL", "", "Authorization service URL for forward auth (e.g., http://authelia:9091)")
	fs.StringVar(&s.AuthPath, "authPath", "/api/authz/forward-auth", "Authorization service endpoint path")
	fs.DurationVar(&s.AuthTimeout, "authTimeout", 5*time.Second, "Timeout for authorization requests")
	fs.Var(&s.AuthCopyHeaders, "authCopyHeader", "Headers to copy from auth response (separated by ': ')")
	fs.BoolVar(&s.AuthInsecureHTTPS, "authInsecureHTTPS", false, "Disable TLS certificate validation for auth service")
	fs.BoolVar(&s.AuthBypassForTailnet, "authBypassForTailnet", false, "Bypass forward auth for requests from Tailscale network (authenticated users)")

	root := &ffcli.Command{
		ShortUsage: fmt.Sprintf("%s [-config <file>] OR [-service \"key=val,...\"] OR [-name <serviceName> [flags] <toURL>]", path.Base(args[0])),
		FlagSet:    fs,
		Exec:       func(context.Context, []string) error { return nil },
	}
	if err := root.Parse(args[1:]); err != nil {
		return nil, "", root, fmt.Errorf("could not parse args: %w", err)
	}

	// Determine which mode we're in
	hasConfigFile := configPath != ""
	hasServiceFlags := len(services) > 0
	hasLegacyFlags := s.Name != "" || len(root.FlagSet.Args()) > 0

	// Check for invalid mode combinations
	if hasConfigFile && hasServiceFlags {
		return nil, "", root, errors.New("cannot use both -config and -service flags; choose one mode")
	}
	if hasConfigFile && hasLegacyFlags {
		return nil, "", root, errConfigAndCLI
	}
	if hasServiceFlags && hasLegacyFlags {
		return nil, "", root, errors.New("cannot mix -service flag with legacy single-service flags; use -service for all services")
	}

	// Mode 1: Config file mode
	if hasConfigFile {
		cfg, err := LoadConfig(configPath)
		if err != nil {
			return nil, "", root, fmt.Errorf("loading config file: %w", err)
		}

		// Use default PrometheusAddr if not specified
		configPrometheusAddr := cfg.PrometheusAddr
		if configPrometheusAddr == "" {
			configPrometheusAddr = ":9099"
		}

		var validServices []*ValidTailnetSrv
		for i, svcCfg := range cfg.Services {
			ts := svcCfg.ToTailnetSrv()
			valid, err := ts.validate([]string{svcCfg.Upstream})
			if err != nil {
				return nil, "", root, fmt.Errorf("validating service %d (%s): %w", i, svcCfg.Name, err)
			}
			validServices = append(validServices, valid)
		}
		return validServices, configPrometheusAddr, root, nil
	}

	// Mode 2: Multi-service CLI mode
	if hasServiceFlags {
		var validServices []*ValidTailnetSrv
		for i, svcCfg := range services {
			ts := svcCfg.ToTailnetSrv()
			valid, err := ts.validate([]string{svcCfg.Upstream})
			if err != nil {
				return nil, "", root, fmt.Errorf("validating service %d (%s): %w", i, svcCfg.Name, err)
			}
			validServices = append(validServices, valid)
		}
		return validServices, prometheusAddr, root, nil
	}

	// Mode 3: Legacy single-service CLI mode
	valid, err := s.validate(root.FlagSet.Args())
	if err != nil {
		return nil, "", root, fmt.Errorf("failed to validate args: %w", err)
	}
	return []*ValidTailnetSrv{valid}, prometheusAddr, root, nil
}

var errNameRequired = errors.New("tsnsrv needs a -name")
var errNoPlaintextOnFunnel = errors.New("can not serve plaintext on a funnel service")
var errBothCertificateFileKeyFile = errors.New("when providing either a certificate or key file, the other must be provided")
var errNoPlaintextWithCustomCert = errors.New("can not serve plaintext when using custom certificate and key")
var errOnlyOneAddrType = errors.New("can only proxy to one address at a time, pass either -upstreamUnixAddr or -upstreamTCPAddr")
var errFunnelRequired = errors.New("-funnel is required if -funnelOnly is set")
var errNoDestURL = errors.New("tsnsrv requires a destination URL")

func (s *TailnetSrv) validate(args []string) (*ValidTailnetSrv, error) {
	var errs []error
	if s.Name == "" {
		errs = append(errs, errNameRequired)
	}
	if s.ServePlaintext && s.Funnel {
		errs = append(errs, errNoPlaintextOnFunnel)
	}
	if s.certificateFile != "" && s.keyFile == "" || s.certificateFile == "" && s.keyFile != "" {
		errs = append(errs, errBothCertificateFileKeyFile)
	}
	if s.ServePlaintext && s.certificateFile != "" && s.keyFile != "" {
		errs = append(errs, errNoPlaintextWithCustomCert)
	}
	if s.UpstreamTCPAddr != "" && s.UpstreamUnixAddr != "" {
		errs = append(errs, errOnlyOneAddrType)
	}
	if !s.Funnel && s.FunnelOnly {
		errs = append(errs, errFunnelRequired)
	}

	if len(args) != 1 {
		return nil, errors.Join(append(errs, errNoDestURL)...)
	}
	destURL, err := url.Parse(args[0])
	if err != nil {
		errs = append(errs, fmt.Errorf("invalid destination URL %#v: %w", args[0], err))
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}

	valid := ValidTailnetSrv{TailnetSrv: *s, DestURL: destURL}
	return &valid, nil
}

func (s *ValidTailnetSrv) authkeyFromFile(ctx context.Context, path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("opening authkey %#v: %w", path, err)
	}
	defer f.Close()
	key, err := io.ReadAll(f)
	if err != nil {
		return "", fmt.Errorf("reading authkey %#v: %w", path, err)
	}
	trimmed := strings.TrimSpace(string(key))
	if strings.HasPrefix(trimmed, "tskey-client-") {
		return s.mintAuthKey(ctx, trimmed)
	}
	return trimmed, nil
}

func (s *ValidTailnetSrv) mintAuthKey(ctx context.Context, authkey string) (string, error) {
	baseURL := cmp.Or(os.Getenv("TS_BASE_URL"), "https://api.tailscale.com")
	tsClient := tailscale.Client{
		Tailnet: "-",
	}
	var err error
	tsClient.BaseURL, err = url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("could not parse base URL %v: %w", baseURL, err)
	}
	credentials := clientcredentials.Config{
		ClientID:     "some-client-id", // ignored
		ClientSecret: authkey,
		TokenURL:     baseURL + "/api/v2/oauth/token",
	}

	tsClient.HTTP = credentials.Client(ctx)
	caps := tailscale.KeyCapabilities{}
	caps.Devices.Create.Reusable = false
	caps.Devices.Create.Tags = s.Tags
	caps.Devices.Create.Ephemeral = s.Ephemeral

	kr := tailscale.KeysResource{Client: &tsClient}
	created, err := kr.Create(ctx, tailscale.CreateKeyRequest{Capabilities: caps})
	if err != nil {
		return "", fmt.Errorf("minting a tailscale pre-authenticated key for tags %v: %w", s.Tags, err)
	}
	return created.Key, nil
}

func (s *ValidTailnetSrv) Run(ctx context.Context) error {
	// Disable Tailscale port listing to reduce CPU usage by ~50%.
	// Port listing polls /proc/net/tcp* and /proc/[pid]/ every 1 second on Linux,
	// consuming significant CPU in multi-service deployments.
	// See: https://github.com/tailscale/tailscale/issues/10430
	os.Setenv("TS_DEBUG_DISABLE_PORTLIST", "true")

	srv := &tsnet.Server{
		Hostname:   s.Name,
		Dir:        s.StateDir,
		Logf:       logger.Discard,
		Ephemeral:  s.Ephemeral,
		ControlURL: os.Getenv("TS_URL"),
	}
	if s.TsnetVerbose {
		slog.SetDefault(slog.Default())
		srv.Logf = log.Printf
	}
	if s.AuthkeyPath != "" {
		var err error
		srv.AuthKey, err = s.authkeyFromFile(ctx, s.AuthkeyPath)
		if err != nil {
			slog.Warn("Could not read authkey from file",
				"path", s.AuthkeyPath,
				"error", err)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, s.Timeout)
	defer cancel()
	status, err := srv.Up(ctx)
	if err != nil {
		return fmt.Errorf("could not connect to tailnet: %w", err)
	}
	s.client, err = srv.LocalClient()
	if err != nil {
		if slices.ContainsFunc(s.AllowedPrefixes, func(p prefix) bool { return p.matchIf != matchEither }) {
			return fmt.Errorf("-prefix rules with a provenance (tailnet: or funnel:) require that a local tailscale client is available: %w", err)
		}
		slog.Warn("could not get a local tailscale client. Whois headers will not work.",
			"error", err,
		)
	}
	dial := srv.Dial
	if s.SuppressTailnetDialer {
		d := net.Dialer{}
		dial = d.DialContext
	}
	if s.UpstreamTCPAddr != "" {
		dialOrig := dial
		dial = func(ctx context.Context, _, _ string) (net.Conn, error) {
			conn, err := dialOrig(ctx, "tcp", s.UpstreamTCPAddr)
			if err != nil {
				return nil, fmt.Errorf("connecting to tcp %v: %w", s.UpstreamTCPAddr, err)
			}
			return conn, nil
		}
	} else if s.UpstreamUnixAddr != "" {
		dial = func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{}
			conn, err := d.DialContext(ctx, "unix", s.UpstreamUnixAddr)
			if err != nil {
				return nil, fmt.Errorf("connecting to unix %v: %w", s.UpstreamUnixAddr, err)
			}
			return conn, nil
		}
	}
	transport := &http.Transport{DialContext: dial}
	transport.TLSClientConfig = &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	if s.InsecureHTTPS {
		transport.TLSClientConfig.InsecureSkipVerify = true // #nosec This is explicitly requested by the user
	}
	if s.UpstreamAllowInsecureCiphers {
		for _, suite := range append(tls.CipherSuites(), tls.InsecureCipherSuites()...) {
			transport.TLSClientConfig.CipherSuites = append(transport.TLSClientConfig.CipherSuites, suite.ID)
		}
	}

	slog.Info("Serving",
		"name", s.Name,
		"tailscaleIPs", status.TailscaleIPs,
		"listenAddr", s.ListenAddr,
		"tags", s.Tags,
		"prefixes", s.AllowedPrefixes,
		"destURL", s.DestURL,
		"plaintext", s.ServePlaintext,
		"funnel", s.Funnel,
		"funnelOnly", s.FunnelOnly,
	)
	tailnetServer := http.Server{
		Handler:           s.mux(transport, false),
		ReadHeaderTimeout: s.ReadHeaderTimeout,
	}
	funnelServer := http.Server{
		Handler:           s.mux(transport, true),
		ReadHeaderTimeout: s.ReadHeaderTimeout,
	}

	serveResults := make(chan error)
	if s.Funnel {
		go func() {
			serveResults <- fmt.Errorf("on the funnel for %v: %w", srv, func() error {
				listener, err := srv.ListenFunnel("tcp", s.ListenAddr, tsnet.FunnelOnly())
				if err != nil {
					return fmt.Errorf("creating funnel listener for %v: %w", srv, err)
				}
				return funnelServer.Serve(listener)
			}())
		}()
	}
	if s.FunnelOnly {
		return fmt.Errorf("while serving: %w", <-serveResults)
	}

	go func() {
		serveResults <- fmt.Errorf("on the tailnet for %v: %w", srv, func() error {
			if s.certificateFile != "" || s.keyFile != "" {
				listener, err := srv.Listen("tcp", s.ListenAddr)
				if err != nil {
					return fmt.Errorf("creating custom-cert TLS listener on the tailnet: %w", err)
				}
				return tailnetServer.ServeTLS(listener, s.certificateFile, s.keyFile)
			}

			listen := func() (net.Listener, error) { return srv.ListenTLS("tcp", s.ListenAddr) }
			if s.ServePlaintext {
				listen = func() (net.Listener, error) { return srv.Listen("tcp", s.ListenAddr) }
			}
			listener, err := listen()
			if err != nil {
				return fmt.Errorf("creating listener on the tailnet: %w", err)
			}
			return tailnetServer.Serve(listener)
		}())
	}()
	return fmt.Errorf("while serving: %w", <-serveResults)
}

// StartPrometheusServer starts the Prometheus metrics and pprof HTTP server on the given address.
// This should be called once at the process level, not per-service.
// Returns an error if the server fails to start, otherwise runs in the background.
func StartPrometheusServer(ctx context.Context, addr string) error {
	if addr == "" {
		return nil
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	// Register pprof handlers for profiling
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("could not listen on prometheus address %v: %w", addr, err)
	}

	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 1 * time.Second,
	}

	go func() {
		slog.Info("Prometheus/pprof server listening", "addr", addr)
		if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
			slog.Error("Prometheus server failed", "error", err)
		}
	}()

	// Gracefully shutdown on context cancellation
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			slog.Error("Error shutting down prometheus server", "error", err)
		}
	}()

	return nil
}
