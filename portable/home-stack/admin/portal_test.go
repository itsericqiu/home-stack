package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	jsonschema "github.com/santhosh-tekuri/jsonschema/v6"
)

func validatePortalSchema(t *testing.T, filename string, document any) {
	t.Helper()

	schemaPath := filepath.Join("..", "..", "..", "schemas", "portal", filename)
	schemaData, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read canonical Portal schema: %v", err)
	}
	var schemaDocument any
	if err := json.Unmarshal(schemaData, &schemaDocument); err != nil {
		t.Fatalf("decode canonical Portal schema: %v", err)
	}

	compiler := jsonschema.NewCompiler()
	compiler.AssertFormat()
	if err := compiler.AddResource(filename, schemaDocument); err != nil {
		t.Fatalf("add canonical Portal schema: %v", err)
	}
	schema, err := compiler.Compile(filename)
	if err != nil {
		t.Fatalf("compile canonical Portal schema: %v", err)
	}

	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("encode projected Portal document: %v", err)
	}
	var jsonDocument any
	if err := json.Unmarshal(encoded, &jsonDocument); err != nil {
		t.Fatalf("decode projected Portal document: %v", err)
	}
	if err := schema.Validate(jsonDocument); err != nil {
		t.Fatalf("projected document does not satisfy %s: %v", filename, err)
	}
}

func TestPortalCatalogProjectionIncludesUnknownAndSanitizesRegistry(t *testing.T) {
	bundleDir := t.TempDir()
	raw := map[string]Service{
		"hermes": {
			DisplayName: "Hermes Agent", Kind: "agent", Type: "proxy", Subdomain: "hermes",
			Upstream: "100.64.0.8:31511", WorkingDir: "/secret/path",
			Args: []string{"--token=secret"}, Env: map[string]string{"TOKEN": "secret"},
		},
		"unknown-worker": {DisplayName: "Unknown Worker", Kind: "worker", Type: "task", Lifecycle: "custom"},
	}
	data, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundleDir, "catalog.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}

	s := &server{bundleDir: bundleDir, parentDomain: "home.example.com"}
	request := httptest.NewRequest(http.MethodGet, portalCatalogPath, nil)
	request.Host = "portal.home.example.com"
	recorder := httptest.NewRecorder()
	s.handlePortalCatalog(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var out portalCatalog
	if err := json.Unmarshal(recorder.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.SchemaVersion != 1 || len(out.Services) != 2 {
		t.Fatalf("unexpected catalog projection: %+v", out)
	}
	if out.Services[0].ID != "hermes" || out.Services[0].URL == nil || *out.Services[0].URL != "https://hermes.home.example.com/" {
		t.Fatalf("Hermes launch projection is wrong: %+v", out.Services[0])
	}
	if out.Services[1].ID != "unknown-worker" || out.Services[1].Launchable || out.Services[1].URL != nil {
		t.Fatalf("unknown headless service must remain visible without a URL: %+v", out.Services[1])
	}
	validatePortalSchema(t, "catalog.v1.schema.json", out)

	body := recorder.Body.String()
	for _, forbidden := range []string{"100.64.0.8", "/secret/path", "token", "TOKEN", "Upstream", "WorkingDir", "Args", "Env", "Health"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("portal catalog leaked %q: %s", forbidden, body)
		}
	}
}

func TestPortalCatalogFailureIsGeneric(t *testing.T) {
	s := &server{bundleDir: t.TempDir(), parentDomain: "home.example.com"}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, portalCatalogPath, nil)
	request.Host = "portal.home.example.com"
	s.handlePortalCatalog(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", recorder.Code)
	}
	if strings.Contains(recorder.Body.String(), s.bundleDir) {
		t.Fatalf("generic failure leaked bundle path: %s", recorder.Body.String())
	}
}

func TestPortalProjectionRejectsNonPortalOrigin(t *testing.T) {
	s := &server{bundleDir: t.TempDir(), parentDomain: "home.example.com"}
	for _, host := range []string{"admin.home.example.com", "127.0.0.1:31510", ""} {
		request := httptest.NewRequest(http.MethodGet, portalCatalogPath, nil)
		request.Host = host
		recorder := httptest.NewRecorder()
		s.handlePortalCatalog(recorder, request)
		if recorder.Code != http.StatusNotFound {
			t.Fatalf("host %q: expected 404, got %d", host, recorder.Code)
		}
	}
}

func TestPortalStatusProjectionDropsPrivilegedDetails(t *testing.T) {
	checkedAt := time.Date(2026, 8, 8, 0, 0, 0, 0, time.UTC)
	services := []serviceStatus{
		{
			Name: "hermes", Kind: "agent", OverallState: "ok",
			Launchd: &launchdStatus{State: "running", PID: "123", Program: "/secret/bin", Stderr: "/secret/log"},
			Port:    &checkStatus{OK: true, State: "open", Target: "100.64.0.8:31511", Details: "private"},
			Route:   &checkStatus{OK: true, State: "present", Target: "hermes.home.example.com"},
			HTTP:    &checkStatus{OK: true, State: "200", Target: "https://hermes.home.example.com/api/status"},
			Actions: []actionDescriptor{{ID: "service.stop", Risk: "high"}},
		},
		{Name: "worker", Kind: "scheduled", OverallState: "unknown", Launchd: &launchdStatus{State: "not running"}},
	}

	out := buildPortalStatus(services, checkedAt)
	if out.OverallState != "degraded" || out.Services["hermes"].Signals.Process != "running" || out.Services["worker"].Signals.Process != "scheduled" {
		t.Fatalf("unexpected status projection: %+v", out)
	}
	validatePortalSchema(t, "status.v1.schema.json", out)
	body, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"123", "/secret", "100.64.0.8", "api/status", "service.stop", "action", "target", "details", "pid", "program", "stderr"} {
		if strings.Contains(strings.ToLower(string(body)), strings.ToLower(forbidden)) {
			t.Fatalf("portal status leaked %q: %s", forbidden, body)
		}
	}
}

func TestPortalProjectionSchemasRejectPrivilegedFields(t *testing.T) {
	catalog := portalCatalog{
		SchemaVersion: 1,
		GeneratedAt:   time.Date(2026, 8, 8, 0, 0, 0, 0, time.UTC),
		Services: []portalCatalogService{{
			ID: "worker", DisplayName: "Worker", Kind: "task", Scope: "local",
			Lifecycle: "external", Launchable: false,
		}},
	}
	encoded, err := json.Marshal(catalog)
	if err != nil {
		t.Fatal(err)
	}
	var unsafe map[string]any
	if err := json.Unmarshal(encoded, &unsafe); err != nil {
		t.Fatal(err)
	}
	unsafe["root"] = "/private/path"

	schemaPath := filepath.Join("..", "..", "..", "schemas", "portal", "catalog.v1.schema.json")
	schemaData, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatal(err)
	}
	var schemaDocument any
	if err := json.Unmarshal(schemaData, &schemaDocument); err != nil {
		t.Fatal(err)
	}
	compiler := jsonschema.NewCompiler()
	if err := compiler.AddResource("catalog.v1.schema.json", schemaDocument); err != nil {
		t.Fatal(err)
	}
	schema, err := compiler.Compile("catalog.v1.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := schema.Validate(unsafe); err == nil {
		t.Fatal("canonical catalog schema accepted a privileged root field")
	}
}

// A disabled service gets no route from the engine, so the Portal catalog
// projection must never hand out a launch URL for it -- but it still needs
// to be listed (a disabled service is inventoried, not hidden), and the
// projection must keep validating against the unmodified schema.
func TestProjectCatalogServiceDisabledIsNonLaunchable(t *testing.T) {
	disabled := false
	svc := projectCatalogService("worker", Service{
		DisplayName: "Worker", Kind: "service", Type: "proxy",
		Subdomain: "worker", Upstream: "127.0.0.1:31700", Enabled: &disabled,
	}, "home.example.com")

	if svc.URL != nil {
		t.Fatalf("disabled service must project url: null, got %+v", *svc.URL)
	}
	if svc.Launchable {
		t.Fatal("disabled service must project launchable: false")
	}
	if svc.ID != "worker" || svc.DisplayName != "Worker" {
		t.Fatalf("disabled service must still be listed: %+v", svc)
	}

	catalog := portalCatalog{
		SchemaVersion: 1,
		GeneratedAt:   time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC),
		Services:      []portalCatalogService{svc},
	}
	validatePortalSchema(t, "catalog.v1.schema.json", catalog)
}

// A disabled service was never meant to run, so it must never drag the
// Portal-wide aggregate down to "degraded" just because its own per-service
// state has nothing better to project than the schema's "unknown" fallback
// (there is no "disabled" value in status.v1.schema.json).
func TestPortalStatusExcludesDisabledFromAggregate(t *testing.T) {
	checkedAt := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	services := []serviceStatus{
		{Name: "admin", OverallState: "ok", Launchd: &launchdStatus{State: "running"}},
		{Name: "disabled-svc", OverallState: "disabled"},
	}

	out := buildPortalStatus(services, checkedAt)
	if out.OverallState != "healthy" {
		t.Fatalf("expected healthy overall state with only a disabled sibling, got %q (%+v)", out.OverallState, out)
	}
	if got := out.Services["disabled-svc"].State; got != "unknown" {
		t.Fatalf("disabled service's own projected state should stay the schema-valid \"unknown\", got %q", got)
	}
	if got := out.Services["admin"].State; got != "healthy" {
		t.Fatalf("healthy sibling should still project healthy, got %q", got)
	}
	validatePortalSchema(t, "status.v1.schema.json", out)
}

func TestGenerateCaddyfileRoutesOnlyPortalProjectionsToAdmin(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"admin":  {DisplayName: "Admin", Kind: "control", Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510"},
		"portal": {DisplayName: "Portal", Kind: "static", Type: "static", Subdomain: "portal", Root: "~/portal/dist"},
	}}
	caddyfile := r.GenerateCaddyfile("acme@example.com", "100.64.0.8", "/Users/test", "home.example.com")

	for _, expected := range []string{
		"@portal_projections path /.well-known/home-stack/catalog.json /.well-known/home-stack/status.json",
		"handle @portal_projections {",
		"reverse_proxy 127.0.0.1:31510",
		"root \"/Users/test/portal/dist\"",
	} {
		if !strings.Contains(caddyfile, expected) {
			t.Fatalf("expected Caddyfile to contain %q, got:\n%s", expected, caddyfile)
		}
	}
}
