package main

import (
	"os"
	"path/filepath"
	"testing"
)

// testServerWithRegistry stages a minimal profile registry and returns a
// server wired to it, mirroring the layout loadActiveRegistry expects.
func testServerWithRegistry(t *testing.T, servicesYAML string) *server {
	t.Helper()
	tmp := t.TempDir()
	bundleDir := filepath.Join(tmp, "portable", "home-stack")
	profileDir := filepath.Join(tmp, "profiles", "testprof")
	for _, d := range []string{bundleDir, profileDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(servicesYAML), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME_STACK_PROFILE", "testprof")
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.test.example")
	return &server{bundleDir: bundleDir}
}

const testRegistryYAML = `services:
  caddy:
    display_name: "Caddy"
    kind: "ingress"
    type: "system"
  admin:
    display_name: "Admin"
    kind: "control"
    lifecycle: managed
    type: "proxy"
    upstream: "127.0.0.1:31510"
  opencode:
    display_name: "OpenCode"
    kind: "backend"
    lifecycle: managed
    type: "proxy"
    upstream: "127.0.0.1:31496"
  logrotate:
    display_name: "Log Rotate"
    kind: "scheduled"
    lifecycle: managed
    type: "task"
  externalsvc:
    display_name: "External"
    kind: "proxy"
    lifecycle: external
    type: "proxy"
    upstream: "127.0.0.1:31900"
  customsvc:
    display_name: "Custom"
    kind: "proxy"
    lifecycle: custom
    type: "proxy"
    upstream: "127.0.0.1:31901"
`

func TestActionDescriptorRequiresConfirmationForCaution(t *testing.T) {
	desc, ok := actionByID("service.restart")
	if !ok {
		t.Fatal("missing service.restart action")
	}
	if desc.Risk != "caution" || !desc.RequiresConfirmation {
		t.Fatalf("restart should be caution with confirmation: %+v", desc)
	}
}

// TestServiceOperationsMatrix pins the lifecycle-derived operation policy.
func TestServiceOperationsMatrix(t *testing.T) {
	cases := []struct {
		name string
		svc  Service
		want map[string]bool
	}{
		{"caddy", Service{Type: "system"}, map[string]bool{"reload": true}},
		{"admin", Service{Type: "proxy", Lifecycle: "managed"}, map[string]bool{"restart": true}},
		{"opencode", Service{Type: "proxy", Lifecycle: "managed"}, map[string]bool{"start": true, "stop": true, "restart": true}},
		{"logrotate", Service{Type: "task", Lifecycle: "managed"}, map[string]bool{"start": true, "restart": true}},
		{"externalsvc", Service{Type: "proxy", Lifecycle: "external"}, nil},
		{"customsvc", Service{Type: "proxy", Lifecycle: "custom"}, nil},
		{"nolifecycle", Service{Type: "proxy"}, nil},
	}
	for _, tc := range cases {
		got := serviceOperations(tc.name, tc.svc)
		for _, op := range []string{"start", "stop", "restart", "reload"} {
			if got[op] != tc.want[op] {
				t.Errorf("%s: op %q = %v, want %v", tc.name, op, got[op], tc.want[op])
			}
		}
	}
}

// TestActionsForServiceMatchesOperations ensures UI buttons and enforcement
// derive from the same policy.
func TestActionsForServiceMatchesOperations(t *testing.T) {
	svc := Service{Type: "proxy", Lifecycle: "managed"}
	got := actionsForService("somesvc", svc)
	ids := map[string]bool{}
	for _, d := range got {
		ids[d.ID] = true
	}
	for _, want := range []string{"service.start", "service.stop", "service.restart"} {
		if !ids[want] {
			t.Errorf("managed service missing action %s", want)
		}
	}

	if got := actionsForService("ext", Service{Type: "proxy", Lifecycle: "external"}); len(got) != 0 {
		t.Errorf("external service should expose no actions, got %d", len(got))
	}

	caddyActions := actionsForService("caddy", Service{Type: "system"})
	caddyIDs := map[string]bool{}
	for _, d := range caddyActions {
		caddyIDs[d.ID] = true
	}
	if !caddyIDs["caddy.validate"] || !caddyIDs["caddy.reload"] {
		t.Errorf("system service should expose caddy.validate and caddy.reload, got %v", caddyIDs)
	}
	if caddyIDs["service.stop"] || caddyIDs["service.restart"] {
		t.Errorf("system service must not expose stop/restart, got %v", caddyIDs)
	}

	adminActions := actionsForService("admin", Service{Type: "proxy", Lifecycle: "managed"})
	adminIDs := map[string]bool{}
	for _, d := range adminActions {
		adminIDs[d.ID] = true
	}
	if adminIDs["service.stop"] || adminIDs["service.start"] {
		t.Errorf("admin must not expose start/stop from its own UI, got %v", adminIDs)
	}
	if !adminIDs["service.restart"] || !adminIDs["admin.restart"] {
		t.Errorf("admin should expose restart, got %v", adminIDs)
	}
}

// A disabled service with no managed lifecycle never had a plist for launchd
// to act on in the first place, so it must expose no operations or actions.
func TestServiceOperationsNilWhenDisabledAndNotManaged(t *testing.T) {
	disabled := false
	cases := []Service{
		{Type: "proxy", Enabled: &disabled},
		{Type: "proxy", Lifecycle: "external", Enabled: &disabled},
		{Type: "proxy", Lifecycle: "custom", Enabled: &disabled},
	}
	for _, svc := range cases {
		if ops := serviceOperations("svc", svc); ops != nil {
			t.Errorf("disabled non-managed service should have no operations, got %+v", ops)
		}
		if actions := actionsForService("svc", svc); len(actions) != 0 {
			t.Errorf("disabled non-managed service should have no actions, got %+v", actions)
		}
	}
}

// A disabled but lifecycle: managed service may still be bootstrapped in
// launchd until install-launchd.sh prunes its plist (Hermes binds the
// Tailnet IP directly, so it stays reachable the whole time) -- stop is the
// one operation that still makes sense; start/restart would fight the
// operator's own decision to disable it.
func TestServiceOperationsStopOnlyWhenDisabledAndManaged(t *testing.T) {
	disabled := false
	cases := []Service{
		{Type: "proxy", Lifecycle: "managed", Enabled: &disabled},
		{Type: "task", Lifecycle: "managed", Enabled: &disabled},
	}
	for _, svc := range cases {
		ops := serviceOperations("svc", svc)
		if len(ops) != 1 || !ops["stop"] {
			t.Errorf("disabled managed service should expose exactly {stop: true}, got %+v", ops)
		}
		actions := actionsForService("svc", svc)
		if len(actions) != 1 || actions[0].ID != "service.stop" {
			t.Errorf("disabled managed service should expose exactly service.stop, got %+v", actions)
		}
	}
}

func TestValidateActionRejectsUnsafeTarget(t *testing.T) {
	s := testServerWithRegistry(t, testRegistryYAML)

	if err := s.validateActionRequest(actionRequest{Action: "service.restart", Target: "caddy", Confirm: true}); err == nil {
		t.Fatal("expected service.restart caddy to be rejected (system services are reload-only)")
	}
	if err := s.validateActionRequest(actionRequest{Action: "caddy.reload", Target: "caddy", Confirm: true}); err != nil {
		t.Fatalf("expected caddy reload to be accepted: %v", err)
	}

	cases := []struct {
		name    string
		req     actionRequest
		wantErr bool
	}{
		{
			name:    "unknown action rejected",
			req:     actionRequest{Action: "unknown.action", Target: "admin", Confirm: true},
			wantErr: true,
		},
		{
			name:    "service.start on admin rejected (restart-only)",
			req:     actionRequest{Action: "service.start", Target: "admin", Confirm: true},
			wantErr: true,
		},
		{
			name:    "service.start on managed service accepted",
			req:     actionRequest{Action: "service.start", Target: "opencode", Confirm: true},
			wantErr: false,
		},
		{
			name:    "service.stop on admin rejected",
			req:     actionRequest{Action: "service.stop", Target: "admin", Confirm: true},
			wantErr: true,
		},
		{
			name:    "service.stop on managed service accepted",
			req:     actionRequest{Action: "service.stop", Target: "opencode", Confirm: true},
			wantErr: false,
		},
		{
			name:    "service.stop on scheduled task rejected",
			req:     actionRequest{Action: "service.stop", Target: "logrotate", Confirm: true},
			wantErr: true,
		},
		{
			name:    "service.start on scheduled task accepted",
			req:     actionRequest{Action: "service.start", Target: "logrotate", Confirm: true},
			wantErr: false,
		},
		{
			name:    "external service not operable",
			req:     actionRequest{Action: "service.restart", Target: "externalsvc", Confirm: true},
			wantErr: true,
		},
		{
			name:    "custom service not operable until Phase F",
			req:     actionRequest{Action: "service.restart", Target: "customsvc", Confirm: true},
			wantErr: true,
		},
		{
			name:    "service not in registry rejected",
			req:     actionRequest{Action: "service.restart", Target: "ghost", Confirm: true},
			wantErr: true,
		},
		{
			name:    "invalid target for caddy.reload rejected",
			req:     actionRequest{Action: "caddy.reload", Target: "admin", Confirm: true},
			wantErr: true,
		},
		{
			name:    "arbitrary action string rejected",
			req:     actionRequest{Action: "rm -rf /", Target: "admin", Confirm: true},
			wantErr: true,
		},
		{
			name:    "arbitrary target string rejected",
			req:     actionRequest{Action: "service.restart", Target: "../../etc/passwd", Confirm: true},
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := s.validateActionRequest(tc.req)
			if tc.wantErr && err == nil {
				t.Fatalf("expected error for case %q, got nil", tc.name)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("unexpected error for case %q: %v", tc.name, err)
			}
		})
	}
}

func TestValidateActionRequiresConfirmation(t *testing.T) {
	s := testServerWithRegistry(t, testRegistryYAML)
	if err := s.validateActionRequest(actionRequest{Action: "service.restart", Target: "opencode", Confirm: false}); err == nil {
		t.Fatal("expected missing confirmation to be rejected")
	}
}
