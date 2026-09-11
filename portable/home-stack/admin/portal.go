package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	portalCatalogPath = "/.well-known/home-stack/catalog.json"
	portalStatusPath  = "/.well-known/home-stack/status.json"
	portalSchemaV1    = 1
)

type portalCatalog struct {
	SchemaVersion int                    `json:"schema_version"`
	GeneratedAt   time.Time              `json:"generated_at"`
	Services      []portalCatalogService `json:"services"`
}

type portalCatalogService struct {
	ID          string  `json:"id"`
	DisplayName string  `json:"display_name"`
	Kind        string  `json:"kind"`
	URL         *string `json:"url"`
	Scope       string  `json:"scope"`
	Lifecycle   string  `json:"lifecycle"`
	Launchable  bool    `json:"launchable"`
}

type portalStatus struct {
	SchemaVersion int                            `json:"schema_version"`
	GeneratedAt   time.Time                      `json:"generated_at"`
	OverallState  string                         `json:"overall_state"`
	Services      map[string]portalServiceStatus `json:"services"`
}

type portalServiceStatus struct {
	State     string              `json:"state"`
	CheckedAt time.Time           `json:"checked_at"`
	Signals   portalHealthSignals `json:"signals"`
}

type portalHealthSignals struct {
	Process string `json:"process"`
	Network string `json:"network"`
	Route   string `json:"route"`
	HTTP    string `json:"http"`
}

func (s *server) handlePortalCatalog(w http.ResponseWriter, r *http.Request) {
	if !s.isPortalOrigin(r) {
		http.NotFound(w, r)
		return
	}
	catalog, err := s.buildPortalCatalog()
	if err != nil {
		writePortalError(w, http.StatusServiceUnavailable, "catalog unavailable")
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=30")
	writeJSON(w, http.StatusOK, catalog)
}

func (s *server) handlePortalStatus(w http.ResponseWriter, r *http.Request) {
	if !s.isPortalOrigin(r) {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	services, err := s.collectServices(ctx)
	if err != nil {
		writePortalError(w, http.StatusServiceUnavailable, "status unavailable")
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, buildPortalStatus(services, time.Now().UTC()))
}

func (s *server) isPortalOrigin(r *http.Request) bool {
	return strings.EqualFold(r.Host, "portal."+s.parentDomain)
}

func writePortalError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, status, struct {
		OK      bool   `json:"ok"`
		Message string `json:"message"`
	}{OK: false, Message: message})
}

func (s *server) buildPortalCatalog() (portalCatalog, error) {
	path := filepath.Join(s.bundleDir, "catalog.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return portalCatalog{}, fmt.Errorf("read generated catalog: %w", err)
	}
	var generated map[string]Service
	if err := json.Unmarshal(data, &generated); err != nil {
		return portalCatalog{}, fmt.Errorf("decode generated catalog: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return portalCatalog{}, fmt.Errorf("stat generated catalog: %w", err)
	}

	services := make([]portalCatalogService, 0, len(generated))
	for id, service := range generated {
		services = append(services, projectCatalogService(id, service, s.parentDomain))
	}
	sort.Slice(services, func(i, j int) bool { return services[i].ID < services[j].ID })

	return portalCatalog{
		SchemaVersion: portalSchemaV1,
		GeneratedAt:   info.ModTime().UTC(),
		Services:      services,
	}, nil
}

func projectCatalogService(id string, service Service, parentDomain string) portalCatalogService {
	displayName := service.DisplayName
	if displayName == "" {
		displayName = id
	}
	kind := service.Kind
	if kind == "" {
		kind = "service"
	}

	var launchURL *string
	// A disabled service gets no route from the engine (see
	// Service.generatesAgentPlist / GenerateCaddyfile), so it is never
	// reachable at its resolved host — project it as present but
	// non-launchable rather than computing a URL that 404s. RoutableURL
	// already folds in that check (and the wildcard/no-host cases).
	if base := service.RoutableURL(parentDomain); base != "" {
		url := base + "/"
		launchURL = &url
	}

	scope := "local"
	if service.Subdomain != "" {
		scope = "tailnet"
	} else if service.Host != "" {
		scope = "external"
	}

	lifecycle := "external"
	switch {
	case service.Type == "static":
		lifecycle = "static"
	case service.Type == "system":
		lifecycle = "system"
	case service.Lifecycle == "managed":
		lifecycle = "managed"
	}

	return portalCatalogService{
		ID:          id,
		DisplayName: displayName,
		Kind:        kind,
		URL:         launchURL,
		Scope:       scope,
		Lifecycle:   lifecycle,
		Launchable:  launchURL != nil,
	}
}

func buildPortalStatus(services []serviceStatus, checkedAt time.Time) portalStatus {
	projected := make(map[string]portalServiceStatus, len(services))
	states := make([]string, 0, len(services))
	for _, service := range services {
		state := portalState(service.OverallState)
		// A disabled service was never meant to run, so it must never drag
		// the stack-wide aggregate down just because its own per-service
		// state has nothing better to report than the schema's "unknown"
		// fallback (there is no "disabled" value in status.v1.schema.json).
		// Its own projected entry below still carries that "unknown" state —
		// it just does not count toward the aggregate.
		if service.OverallState != "disabled" {
			states = append(states, state)
		}
		projected[service.Name] = portalServiceStatus{
			State:     state,
			CheckedAt: checkedAt,
			Signals: portalHealthSignals{
				Process: portalProcessSignal(service),
				Network: portalCheckSignal(service.Port, "reachable", "unreachable", "not_checked"),
				Route:   portalCheckSignal(service.Route, "ready", "missing", "not_applicable"),
				HTTP:    portalCheckSignal(service.HTTP, "healthy", "unhealthy", "not_checked"),
			},
		}
	}
	return portalStatus{
		SchemaVersion: portalSchemaV1,
		GeneratedAt:   checkedAt,
		OverallState:  aggregatePortalState(states),
		Services:      projected,
	}
}

func portalState(state string) string {
	switch state {
	case "ok", "healthy":
		return "healthy"
	case "warn", "degraded":
		return "degraded"
	case "down", "unavailable":
		return "unavailable"
	default:
		return "unknown"
	}
}

func aggregatePortalState(states []string) string {
	if len(states) == 0 {
		return "unknown"
	}
	allUnknown := true
	degraded := false
	for _, state := range states {
		switch state {
		case "unavailable":
			return "unavailable"
		case "degraded":
			degraded = true
			allUnknown = false
		case "unknown":
			degraded = true
		default:
			allUnknown = false
		}
	}
	if allUnknown {
		return "unknown"
	}
	if degraded {
		return "degraded"
	}
	return "healthy"
}

func portalProcessSignal(service serviceStatus) string {
	if service.Launchd == nil {
		return "not_managed"
	}
	if service.Kind == "scheduled" && service.Launchd.State != "running" {
		return "scheduled"
	}
	switch service.Launchd.State {
	case "running":
		return "running"
	case "not running", "not loaded", "stopped", "exited":
		return "stopped"
	default:
		return "unknown"
	}
}

func portalCheckSignal(check *checkStatus, healthy, unhealthy, absent string) string {
	if check == nil {
		return absent
	}
	if check.OK {
		return healthy
	}
	return unhealthy
}
