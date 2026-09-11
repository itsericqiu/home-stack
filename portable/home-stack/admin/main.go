package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed templates/index.html templates/app.js templates/app.css
var templatesFS embed.FS

const defaultCaddyAdminURL = "http://127.0.0.1:2019"

type response struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Details string `json:"details,omitempty"`
}

type server struct {
	bundleDir     string
	caddyAdminURL string
	parentDomain  string
	adminUsername string
	adminPassword string
	// Shared secret proving a request arrived through the Caddy ingress rather
	// than straight to this loopback listener. Without it the X-Webauth-*
	// identity headers are unauthenticated user input.
	proxyAuthSecret string
	client          *http.Client
	launchdCache    []launchdService
	launchdCacheAt  time.Time
	launchdCacheMu  sync.Mutex
}

type launchdService struct {
	Name         string `json:"name"`
	Scope        string `json:"scope"`
	Domain       string `json:"domain"`
	Label        string `json:"label"`
	State        string `json:"state"`
	PID          string `json:"pid"`
	LastExitCode string `json:"last_exit_code"`
	Program      string `json:"program"`
	Path         string `json:"path"`
	Stdout       string `json:"stdout"`
	Stderr       string `json:"stderr"`
}

type serviceStatus struct {
	Name         string             `json:"name"`
	DisplayName  string             `json:"display_name"`
	Kind         string             `json:"kind"`
	OverallState string             `json:"overall_state"`
	Desired      *Service           `json:"desired,omitempty"`
	Launchd      *launchdStatus     `json:"launchd,omitempty"`
	Port         *checkStatus       `json:"port,omitempty"`
	Route        *checkStatus       `json:"route,omitempty"`
	HTTP         *checkStatus       `json:"http,omitempty"`
	Actions      []actionDescriptor `json:"actions,omitempty"`
	Details      string             `json:"details,omitempty"`
}

type launchdStatus struct {
	State        string `json:"state"`
	PID          string `json:"pid,omitempty"`
	LastExitCode string `json:"last_exit_code,omitempty"`
	Program      string `json:"program,omitempty"`
	Stdout       string `json:"stdout,omitempty"`
	Stderr       string `json:"stderr,omitempty"`
}

type checkStatus struct {
	OK      bool   `json:"ok"`
	State   string `json:"state"`
	Target  string `json:"target,omitempty"`
	Details string `json:"details,omitempty"`
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "sync":
			if err := runSync(); err != nil {
				fmt.Fprintln(os.Stderr, "sync failed:", err)
				os.Exit(1)
			}
			return
		case "launchd-status":
			if err := runLaunchdStatus(os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, "launchd-status failed:", err)
				os.Exit(1)
			}
			return
		}
	}
	runServer()
}

func runSync() error {
	if err := validateEnv(); err != nil {
		return err
	}
	bundleDir, err := discoverBundleDir()
	if err != nil {
		return err
	}
	s := &server{bundleDir: bundleDir}
	out, err := s.syncSystem()
	if err != nil {
		return err
	}
	fmt.Println(out)
	return nil
}

// runLaunchdStatus implements the launchd-status subcommand
func runLaunchdStatus(args []string) error {
	mode := "table"
	var filter string

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			mode = "json"
		case "--table":
			mode = "table"
		case "--verbose":
			mode = "verbose"
		case "--help", "-h":
			fmt.Fprintln(os.Stderr, "Usage: home-stack-admin launchd-status [--json|--table|--verbose] [service]")
			return nil
		default:
			if strings.HasPrefix(args[i], "-") {
				return fmt.Errorf("unknown option: %s", args[i])
			}
			filter = args[i]
		}
	}

	bundleDir, err := discoverBundleDir()
	if err != nil {
		return err
	}

	services, err := collectLaunchdServices(bundleDir, filter)
	if err != nil {
		return err
	}

	switch mode {
	case "json":
		enc := json.NewEncoder(os.Stdout)
		enc.SetEscapeHTML(false)
		return enc.Encode(services)
	case "table":
		fmt.Printf("%-13s %-7s %-13s %-7s %-14s %s\n", "SERVICE", "SCOPE", "STATE", "PID", "EXIT", "PROGRAM")
		for _, svc := range services {
			pid := svc.PID
			if pid == "" {
				pid = "-"
			}
			exitCode := svc.LastExitCode
			if exitCode == "" {
				exitCode = "-"
			}
			program := svc.Program
			if program == "" {
				program = "-"
			}
			fmt.Printf("%-13s %-7s %-13s %-7s %-14s %s\n", svc.Name, svc.Scope, svc.State, pid, exitCode, filepath.Base(program))
		}
	case "verbose":
		for _, svc := range services {
			fmt.Printf("== %s/%s ==\n", svc.Domain, svc.Label)
			if svc.State == "not loaded" {
				fmt.Println("not loaded")
			} else {
				// Print filtered launchctl output
				output, _ := launchctlPrint(context.Background(), svc.Domain, svc.Label)
				printFilteredOutput(output)
			}
			fmt.Println()
		}
	}
	return nil
}

// printFilteredOutput prints only relevant launchctl fields
func printFilteredOutput(output string) {
	lines := strings.Split(output, "\n")
	relevant := []string{"state =", "pid =", "last exit code =", "program =", "path =", "stdout path =", "stderr path ="}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		for _, prefix := range relevant {
			if strings.HasPrefix(trimmed, prefix) {
				fmt.Println(trimmed)
				break
			}
		}
	}
}

// collectLaunchdServices discovers and collects status for all home-stack launchd services
func collectLaunchdServices(bundleDir string, filter string) ([]launchdService, error) {
	uid := os.Getenv("HOME_STACK_OWNER_UID")
	if uid == "" {
		uid = strconv.Itoa(os.Getuid())
	}

	identifierPrefix := os.Getenv("HOME_STACK_IDENTIFIER_PREFIX")
	if identifierPrefix == "" {
		return nil, fmt.Errorf("HOME_STACK_IDENTIFIER_PREFIX is not set")
	}

	homeDir := os.Getenv("HOME_STACK_OWNER_HOME")
	if homeDir == "" {
		homeDir = os.Getenv("HOME")
	}

	userAgentDir := filepath.Join(homeDir, "Library/LaunchAgents")
	daemonDir := "/Library/LaunchDaemons"

	plistPattern := identifierPrefix + ".home-stack.*.plist"

	var services []launchdService

	dirs := []struct {
		dir   string
		scope string
	}{
		{userAgentDir, "user"},
		{daemonDir, "system"},
	}

	for _, d := range dirs {
		matches, err := filepath.Glob(filepath.Join(d.dir, plistPattern))
		if err != nil {
			continue
		}
		for _, plistPath := range matches {
			name := filepath.Base(plistPath)
			name = strings.TrimPrefix(name, identifierPrefix+".home-stack.")
			name = strings.TrimSuffix(name, ".plist")

			if filter != "" && name != filter {
				continue
			}

			svc := launchdService{
				Name:   name,
				Scope:  d.scope,
				Domain: domainForScope(d.scope, uid),
				Label:  identifierPrefix + ".home-stack." + name,
				Path:   plistPath,
				State:  "not loaded",
			}

			// Get program from plist
			svc.Program = programFromPlist(plistPath)

			// Get status from launchctl
			populateLaunchdStatus(&svc)

			services = append(services, svc)
		}
	}

	return services, nil
}

func domainForScope(scope, uid string) string {
	if scope == "system" {
		return "system"
	}
	return "gui/" + uid
}

func programFromPlist(plistPath string) string {
	cmd := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print :ProgramArguments:0", plistPath)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func populateLaunchdStatus(svc *launchdService) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	output, err := launchctlPrint(ctx, svc.Domain, svc.Label)
	if err != nil {
		return
	}

	svc.State = parseLaunchctlField(output, "state")
	svc.PID = parseLaunchctlField(output, "pid")
	svc.LastExitCode = parseLaunchctlField(output, "last exit code")
	stdoutPath := parseLaunchctlField(output, "stdout path")
	stderrPath := parseLaunchctlField(output, "stderr path")
	svc.Stdout = stdoutPath
	svc.Stderr = stderrPath

	// Override program if runtime program is available
	if runtimeProgram := parseLaunchctlField(output, "program"); runtimeProgram != "" {
		svc.Program = runtimeProgram
	}
}

func launchctlPrint(ctx context.Context, domain, label string) (string, error) {
	target := domain + "/" + label
	cmd := exec.CommandContext(ctx, "launchctl", "print", target)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), nil
	}

	// For system domain, try with sudo -n
	if domain == "system" {
		cmd = exec.CommandContext(ctx, "sudo", "-n", "launchctl", "print", target)
		out, err = cmd.CombinedOutput()
		if err == nil {
			return string(out), nil
		}
	}

	return "", err
}

func parseLaunchctlField(output, field string) string {
	lines := strings.Split(output, "\n")
	prefix := field + " = "
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			value := strings.TrimPrefix(line, prefix)
			value = strings.TrimSpace(value)
			// Remove quotes if present
			if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
				value = value[1 : len(value)-1]
			}
			return value
		}
	}
	return ""
}

func (s *server) launchdServices(ctx context.Context) ([]launchdService, error) {
	s.launchdCacheMu.Lock()
	defer s.launchdCacheMu.Unlock()

	if time.Since(s.launchdCacheAt) < 30*time.Second && s.launchdCache != nil {
		return s.launchdCache, nil
	}

	bundleDir, err := discoverBundleDir()
	if err != nil {
		return nil, err
	}
	services, err := collectLaunchdServices(bundleDir, "")
	if err != nil {
		return nil, err
	}
	s.launchdCache = services
	s.launchdCacheAt = time.Now()
	return services, nil
}

func runServer() {
	bundleDir, err := discoverBundleDir()
	if err != nil {
		log.Fatal(err)
	}

	if err := validateEnv(); err != nil {
		log.Fatal(err)
	}

	addr := os.Getenv("HOME_STACK_ADMIN_ADDR")
	if addr == "" {
		port := os.Getenv("HOME_STACK_ADMIN_PORT")
		if port == "" {
			port = "31510"
		}
		addr = "127.0.0.1:" + port
	}

	caddyAdminURL, err := localCaddyAdminURL(envDefault("HOME_STACK_CADDY_ADMIN_URL", defaultCaddyAdminURL))
	if err != nil {
		log.Fatal(err)
	}

	s := &server{
		bundleDir:       bundleDir,
		caddyAdminURL:   caddyAdminURL,
		parentDomain:    os.Getenv("HOME_STACK_PARENT_DOMAIN"),
		adminUsername:   os.Getenv("HOME_STACK_ADMIN_USERNAME"),
		adminPassword:   os.Getenv("HOME_STACK_ADMIN_PASSWORD"),
		proxyAuthSecret: os.Getenv("HOME_STACK_ADMIN_PROXY_SECRET"),
		client:          &http.Client{Timeout: 5 * time.Second},
	}

	mux := http.NewServeMux()
	// These two exact read-only routes are the intentionally public Portal
	// boundary. All Admin UI, diagnostics, and mutations remain authenticated.
	mux.Handle(portalCatalogPath, s.withMethod(http.MethodGet, http.HandlerFunc(s.handlePortalCatalog)))
	mux.Handle(portalStatusPath, s.withMethod(http.MethodGet, http.HandlerFunc(s.handlePortalStatus)))
	mux.Handle("/", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleAdmin))))
	mux.Handle("/assets/", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleAsset))))
	mux.Handle("/api/health", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleHealth))))
	mux.Handle("/api/status", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleStatus))))
	mux.Handle("/api/overview", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleOverview))))
	mux.Handle("/api/incidents", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleIncidents))))
	mux.Handle("/api/events", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleEvents))))
	mux.Handle("/api/doctor", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleDoctor))))
	mux.Handle("/api/deploy/preview", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleDeployPreview))))
	mux.Handle("/api/services", s.withAuth(s.withMethod(http.MethodGet, http.HandlerFunc(s.handleServices))))
	mux.Handle("/api/actions", s.withAuth(s.withMutation(s.withMethod(http.MethodPost, http.HandlerFunc(s.handleAction)))))

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	// Graceful shutdown
	done := make(chan bool, 1)
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-quit
		log.Println("home-stack admin shutting down...")
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Fatalf("could not gracefully shutdown: %v", err)
		}
		close(done)
	}()

	log.Printf("home-stack admin listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("listen: %s\n", err)
	}

	<-done
	log.Println("home-stack admin stopped")
}

func (s *server) withMethod(method string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			w.Header().Set("Allow", method)
			writeJSON(w, http.StatusMethodNotAllowed, response{OK: false, Message: "method not allowed"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// proxyIdentity returns the identity Caddy resolved for this request, or "" if
// the request did not arrive through Caddy's authenticated ingress.
//
// The identity headers alone prove nothing: this server listens on loopback, so
// any local process can set X-Webauth-User and claim to be anyone. What makes
// them trustworthy is the shared secret, which only the ingress knows and
// injects. Both must be present -- the secret proves the hop, the header names
// the user.
func (s *server) proxyIdentity(r *http.Request) string {
	if s.proxyAuthSecret == "" {
		return ""
	}
	presented := r.Header.Get("X-Home-Stack-Proxy-Auth")
	if subtle.ConstantTimeCompare([]byte(presented), []byte(s.proxyAuthSecret)) != 1 {
		return ""
	}
	// Two lanes name the user differently: tailnet identity arrives as
	// X-Webauth-User, while the broker's forward-auth response is copied
	// through as Remote-User.
	if user := r.Header.Get("X-Webauth-User"); user != "" {
		return user
	}
	return r.Header.Get("Remote-User")
}

func (s *server) withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Identity established at the ingress: no prompt, the user already
		// authenticated there (tailnet identity, or the broker's login).
		if user := s.proxyIdentity(r); user != "" {
			next.ServeHTTP(w, r)
			return
		}

		// Basic Auth remains as the second factor and the break-glass path.
		// Admin is the tool used to repair a broken identity layer, so it must
		// stay reachable when that layer is the thing that is broken -- and it
		// is what protects the loopback listener from local callers.
		if s.adminPassword == "" {
			writeJSON(w, http.StatusServiceUnavailable, response{OK: false, Message: "admin password is not configured; set HOME_STACK_ADMIN_PASSWORD in env.local"})
			return
		}
		username, password, ok := r.BasicAuth()
		if ok && subtle.ConstantTimeCompare([]byte(username), []byte(s.adminUsername)) == 1 && subtle.ConstantTimeCompare([]byte(password), []byte(s.adminPassword)) == 1 {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("WWW-Authenticate", `Basic realm="home-stack admin", charset="UTF-8"`)
		writeJSON(w, http.StatusUnauthorized, response{OK: false, Message: "authentication required"})
	})
}

func (s *server) withMutation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Home-Stack-Admin") != "1" {
			writeJSON(w, http.StatusForbidden, response{OK: false, Message: "missing admin mutation header"})
			return
		}
		origin := r.Header.Get("Origin")
		referer := r.Header.Get("Referer")

		valid := false
		if origin != "" {
			u, err := url.Parse(origin)
			if err == nil && strings.EqualFold(u.Host, r.Host) {
				valid = true
			}
		} else if referer != "" {
			u, err := url.Parse(referer)
			if err == nil && strings.EqualFold(u.Host, r.Host) {
				valid = true
			}
		} else {
			// No origin or referer; allow if X-Home-Stack-Admin is set (non-browser or very old browser)
			// but in a strict sense, we prefer having one. For now, trust the custom header.
			valid = true
		}

		if !valid {
			writeJSON(w, http.StatusForbidden, response{OK: false, Message: "invalid mutation origin/referer"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) handleAdmin(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	tmpl, err := template.ParseFS(templatesFS, "templates/index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = tmpl.Execute(w, map[string]string{
		"CaddyAdminURL": s.caddyAdminURL,
		"ParentDomain":  s.parentDomain,
	})
}

// handleAsset serves the webapp's static files from the embedded FS. Only
// explicitly known assets are served — no directory listing, no path echo.
func (s *server) handleAsset(w http.ResponseWriter, r *http.Request) {
	assets := map[string]string{
		"/assets/app.js":  "text/javascript; charset=utf-8",
		"/assets/app.css": "text/css; charset=utf-8",
	}
	contentType, ok := assets[r.URL.Path]
	if !ok {
		http.NotFound(w, r)
		return
	}
	data, err := templatesFS.ReadFile("templates/" + strings.TrimPrefix(r.URL.Path, "/assets/"))
	if err != nil {
		http.Error(w, "asset unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentType)
	_, _ = w.Write(data)
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, response{OK: true, Message: "home-stack admin healthy"})
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	msg := "caddy admin reachable"
	ok := true
	if err := s.checkCaddyAdmin(ctx); err != nil {
		ok = false
		msg = "caddy admin unreachable"
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              ok,
		"message":         msg,
		"caddy_admin_url": s.caddyAdminURL,
		"bundle_dir":      s.bundleDir,
		"time":            time.Now().Format(time.RFC3339),
	})
}

func (s *server) handleServices(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	services, err := s.collectServices(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to load services", Details: err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"time":     time.Now().Format(time.RFC3339),
		"services": services,
	})
}

// activeProfile resolves the profile name the same way the shell tooling does.
func activeProfile() string {
	if p := os.Getenv("HOME_STACK_PROFILE"); p != "" {
		return p
	}
	return os.Getenv("USER")
}

// loadActiveRegistry loads the registry for the active profile. It is the one
// sanctioned way for handlers to consult the registry.
func (s *server) loadActiveRegistry() (*Registry, error) {
	path := registryPath(s.bundleDir, activeProfile())
	return loadRegistry(path)
}

func (s *server) collectServices(ctx context.Context) ([]serviceStatus, error) {
	registry, err := s.loadActiveRegistry()
	if err != nil {
		return nil, err
	}

	launchd, _ := s.launchdServices(ctx)
	byName := map[string]launchdService{}
	for _, svc := range launchd {
		byName[svc.Name] = svc
	}

	caddyConfig, _ := s.getCaddyConfig(ctx)

	var services []serviceStatus
	for name, svc := range registry.Services {
		sCopy := svc // create redacted copy for pointer
		sCopy.Args = nil
		sCopy.Env = nil
		status := serviceStatus{
			Name:        name,
			DisplayName: svc.DisplayName,
			Kind:        svc.Kind,
			Desired:     &sCopy,
		}

		// A launchd lookup is populated whether or not the service is
		// disabled: a service flipped to enabled: false stays bootstrapped
		// (still loaded, potentially still running) until install-launchd.sh
		// prunes its plist, and Hermes-style services that bind the Tailnet
		// IP directly stay reachable the whole time. Hiding that behind the
		// disabled short-circuit below would make a still-running disabled
		// service look identical to one that was cleanly uninstalled.
		if l, ok := byName[name]; ok {
			status.Launchd = &launchdStatus{
				State:        l.State,
				PID:          l.PID,
				LastExitCode: l.LastExitCode,
				Program:      l.Program,
				Stdout:       l.Stdout,
				Stderr:       l.Stderr,
			}
		}

		// A disabled service is inventoried but never probed further: the
		// engine emits no route and no plist for it (see
		// generatesAgentPlist), so port/route/http checks would only ever
		// report failure — not because the service is unhealthy, but because
		// it was never meant to run. "disabled" is a fifth, neutral overall
		// state, distinct from "down" or "unknown".
		if !svc.IsEnabled() {
			status.OverallState = "disabled"
			status.Actions = actionsForService(name, svc)
			services = append(services, status)
			continue
		}

		if svc.Upstream != "" {
			status.Port = checkPort(ctx, svc.Upstream)
		}

		parentDomain, _ := requiredParentDomain()
		if resolved := svc.RoutableHost(parentDomain); resolved != "" {
			status.Route = checkRoute(caddyConfig, resolved)
		}

		if svc.Health.HTTPURL != "" {
			status.HTTP = s.checkHTTP(ctx, svc.Health.HTTPURL, name == "admin")
		}

		status.OverallState = deriveOverall(status)
		status.Actions = actionsForService(name, svc)
		services = append(services, status)
	}

	sort.Slice(services, func(i, j int) bool {
		return services[i].Name < services[j].Name
	})

	return services, nil
}

func (s *server) handleOverview(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	services, err := s.collectServices(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to collect services", Details: err.Error()})
		return
	}

	incidents := deriveIncidents(services)
	counts := countServiceStates(services)

	recent, _ := s.readEvents(10)

	writeJSON(w, http.StatusOK, overviewResponse{
		OK:            true,
		OverallState:  overallStateFromIncidents(incidents),
		GeneratedAt:   time.Now(),
		ServiceCounts: counts,
		TopIncidents:  incidents,
		RecentEvents:  recent,
		Connection:    connectionStatus{Backend: "reachable", Caddy: "unknown"},
	})
}

func (s *server) handleIncidents(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	services, err := s.collectServices(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to collect incidents", Details: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "incidents": deriveIncidents(services)})
}

func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	events, err := s.readEvents(50)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to read events", Details: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "events": events})
}

func (s *server) handleAction(w http.ResponseWriter, r *http.Request) {
	var req actionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, response{OK: false, Message: "invalid action request"})
		return
	}
	if err := s.validateActionRequest(req); err != nil {
		writeJSON(w, http.StatusBadRequest, response{OK: false, Message: "action rejected", Details: err.Error()})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	// Attribute the mutation to whoever actually authenticated. Under proxy
	// identity there is no Basic header at all, so reading only BasicAuth left
	// zero-click mutations audited with an empty actor.
	actor := s.proxyIdentity(r)
	if actor == "" {
		actor, _, _ = r.BasicAuth()
	}
	result := s.executeAction(ctx, actor, req)
	if !result.OK {
		writeJSON(w, http.StatusBadRequest, result)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *server) handleDoctor(w http.ResponseWriter, r *http.Request) {
	checks := s.doctorChecks()
	ok := true
	for _, check := range checks {
		if check.State == "fail" {
			ok = false
		}
	}
	writeJSON(w, http.StatusOK, doctorResponse{OK: ok, Checks: checks})
}

func (s *server) handleDeployPreview(w http.ResponseWriter, r *http.Request) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	diff, err := Diff(s.bundleDir, profile)
	if err != nil {
		regPath := registryPath(s.bundleDir, profile)
		registry, regErr := loadRegistry(regPath)
		if regErr != nil {
			writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to load registry", Details: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, buildDeployPreview(registry))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "diff": diff, "has_changes": diff.HasChanges})
}

func (s *server) handleServiceAction(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/services/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		writeJSON(w, http.StatusNotFound, response{OK: false, Message: "unknown service action"})
		return
	}
	service, action := parts[0], parts[1]
	ctx, cancel := context.WithTimeout(r.Context(), 45*time.Second)
	defer cancel()

	out, err := s.runServiceAction(ctx, service, action)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, response{OK: false, Message: fmt.Sprintf("%s %s failed", service, action), Details: out})
		return
	}
	writeJSON(w, http.StatusOK, response{OK: true, Message: fmt.Sprintf("%s %s completed", service, action), Details: out})
}

func (s *server) handleSync(w http.ResponseWriter, r *http.Request) {
	out, err := s.syncSystem()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "sync failed", Details: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, response{OK: true, Message: "system synced from registry", Details: out})
}

type registryAddRequest struct {
	Name    string  `json:"name"`
	Service Service `json:"service"`
}

func (s *server) handleRegistryAdd(w http.ResponseWriter, r *http.Request) {
	var req registryAddRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, response{OK: false, Message: "invalid request body"})
		return
	}

	if req.Name == "" {
		writeJSON(w, http.StatusBadRequest, response{OK: false, Message: "service name is required"})
		return
	}

	if err := s.addServiceToRegistry(req.Name, req.Service); err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "failed to add service", Details: err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, response{OK: true, Message: fmt.Sprintf("service %q added to registry", req.Name)})
}

func (s *server) handleCaddyConfig(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	body, err := s.getCaddyConfig(ctx)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, response{OK: false, Message: "failed to read Caddy config", Details: err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *server) handleCaddyValidate(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	// Regenerate Caddyfile from registry before validating.
	if out, err := s.syncSystem(); err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "sync failed", Details: out})
		return
	}
	out, err := s.run(ctx, filepath.Join(s.bundleDir, "bin", "caddy-cloudflare"), "validate", "--config", filepath.Join(s.bundleDir, "Caddyfile"))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "validation failed", Details: out})
		return
	}
	writeJSON(w, http.StatusOK, response{OK: true, Message: "Caddy config valid", Details: out})
}

func (s *server) handleCaddyReload(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 45*time.Second)
	defer cancel()

	out, err := s.run(ctx, filepath.Join(s.bundleDir, "scripts", "reload-caddy.sh"))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, response{OK: false, Message: "reload failed", Details: out})
		return
	}
	writeJSON(w, http.StatusOK, response{OK: true, Message: "Caddy config reloaded", Details: out})
}

func (s *server) checkCaddyAdmin(ctx context.Context) error {
	_, err := s.getCaddyConfig(ctx)
	return err
}

func (s *server) runServiceAction(ctx context.Context, service, action string) (string, error) {
	reg, err := s.loadActiveRegistry()
	if err != nil {
		return "", fmt.Errorf("cannot load registry to authorize action: %w", err)
	}
	svc, ok := reg.Services[service]
	if !ok {
		return "", fmt.Errorf("unknown service %q", service)
	}
	if !serviceOperations(service, svc)[action] {
		return "", fmt.Errorf("action %q is not allowed for service %q", action, service)
	}
	if service == "caddy" && action == "reload" {
		return s.run(ctx, filepath.Join(s.bundleDir, "scripts", "reload-caddy.sh"))
	}
	return s.run(ctx, filepath.Join(s.bundleDir, "scripts", "service-launchd.sh"), action, service)
}

func (s *server) getCaddyConfig(ctx context.Context) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.caddyAdminURL+"/config/", nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("Caddy Admin API returned %s", resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 2<<20))
}

func checkPort(ctx context.Context, target string) *checkStatus {
	dialer := net.Dialer{Timeout: 2 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", target)
	if err != nil {
		return &checkStatus{OK: false, State: "closed", Target: target, Details: err.Error()}
	}
	_ = conn.Close()
	return &checkStatus{OK: true, State: "open", Target: target}
}

func checkRoute(caddyConfig []byte, host string) *checkStatus {
	if len(caddyConfig) == 0 {
		return &checkStatus{OK: false, State: "unknown", Target: host, Details: "Caddy config unavailable"}
	}

	// Robust Caddy route check: walk the JSON looking for host matches
	var cfg any
	if err := json.Unmarshal(caddyConfig, &cfg); err != nil {
		// Fallback to substring match if JSON is invalid for some reason
		if strings.Contains(string(caddyConfig), host) {
			return &checkStatus{OK: true, State: "loaded", Target: host}
		}
		return &checkStatus{OK: false, State: "error", Target: host, Details: "failed to parse Caddy config"}
	}

	if findHostInCaddyConfig(cfg, host) {
		return &checkStatus{OK: true, State: "loaded", Target: host}
	}

	return &checkStatus{OK: false, State: "missing", Target: host}
}

func findHostInCaddyConfig(v any, host string) bool {
	switch val := v.(type) {
	case string:
		return strings.EqualFold(val, host)
	case []any:
		for _, item := range val {
			if findHostInCaddyConfig(item, host) {
				return true
			}
		}
	case map[string]any:
		for k, v := range val {
			if k == "host" {
				if findHostInCaddyConfig(v, host) {
					return true
				}
			}
			if findHostInCaddyConfig(v, host) {
				return true
			}
		}
	}
	return false
}

func (s *server) checkHTTP(ctx context.Context, target string, basicAuth bool) *checkStatus {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return &checkStatus{OK: false, State: "invalid", Target: target, Details: err.Error()}
	}
	if basicAuth && s.adminPassword != "" {
		req.SetBasicAuth(s.adminUsername, s.adminPassword)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return &checkStatus{OK: false, State: "error", Target: target, Details: err.Error()}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
	state := fmt.Sprintf("%d", resp.StatusCode)
	return &checkStatus{OK: resp.StatusCode >= 200 && resp.StatusCode < 400, State: state, Target: target}
}

func deriveOverall(status serviceStatus) string {
	warn := false
	checks := 0
	if status.Launchd != nil {
		checks++
		if status.Launchd.State == "running" || (status.Launchd.State == "not running" && status.Kind == "scheduled") {
			// ok
		} else if status.Launchd.State == "not loaded" {
			return "down"
		} else {
			warn = true
		}
	}
	for _, check := range []*checkStatus{status.Port, status.Route, status.HTTP} {
		if check == nil {
			continue
		}
		checks++
		if !check.OK {
			return "down"
		}
	}
	if checks == 0 {
		return "unknown"
	}
	if warn {
		return "warn"
	}
	return "ok"
}

func (s *server) run(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = s.bundleDir
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	out := strings.TrimSpace(buf.String())

	// UTF-8 safe truncation
	if len(out) > 4000 {
		runes := []rune(out)
		if len(runes) > 1000 {
			out = string(runes[:1000]) + "\n...truncated..."
		}
	}

	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return out, ctx.Err()
	}
	return out, err
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func localCaddyAdminURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return "", err
	}
	if u.Scheme != "http" {
		return "", fmt.Errorf("Caddy Admin API URL must use http and stay localhost-only")
	}
	host := u.Hostname()
	if strings.EqualFold(host, "localhost") || host == "127.0.0.1" || host == "::1" {
		return u.String(), nil
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return u.String(), nil
	}
	return "", fmt.Errorf("Caddy Admin API URL must stay localhost-only, got host %q", host)
}

func discoverBundleDir() (string, error) {
	if value := os.Getenv("HOME_STACK_BUNDLE_DIR"); value != "" {
		return filepath.Abs(value)
	}
	exe, err := os.Executable()
	if err == nil {
		if dir, ok := bundleFromPath(exe); ok {
			return dir, nil
		}
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	if dir, ok := bundleFromPath(wd); ok {
		return dir, nil
	}
	return "", fmt.Errorf("could not discover HOME_STACK_BUNDLE_DIR")
}

func bundleFromPath(path string) (string, bool) {
	dir := path
	info, err := os.Stat(dir)
	if err == nil && !info.IsDir() {
		dir = filepath.Dir(dir)
	}
	for {
		if filepath.Base(dir) == "admin" && filepath.Base(filepath.Dir(dir)) == "home-stack" {
			return filepath.Dir(dir), true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}
