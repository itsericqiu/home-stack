package main

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// A disabled service is inventoried by collectServices but never probed
// further: port/route/http checks would only ever report failure for a
// service that was never meant to run, so none of them execute, and
// OverallState is the dedicated "disabled" value rather than "down" or
// "unknown". Launchd is still populated when the service happens to still be
// loaded (e.g. before install-launchd.sh has pruned its stale plist) -- a
// disabled service is not necessarily an uninstalled one -- and since its
// lifecycle is "managed" it exposes exactly a service.stop action.
func TestCollectServicesSkipsChecksForDisabledService(t *testing.T) {
	s := testServerWithRegistry(t, `services:
  admin:
    display_name: "Admin"
    kind: "control"
    lifecycle: managed
    type: "proxy"
    upstream: "127.0.0.1:31510"
  disabled-svc:
    display_name: "Disabled"
    kind: "backend"
    lifecycle: managed
    type: "proxy"
    upstream: "127.0.0.1:31999"
    subdomain: disabled-svc
    health:
      port: 31999
    enabled: false
`)
	// collectServices probes Caddy's admin API for the route check; give it
	// a real (if unreachable) client instead of the zero value, and a
	// caddyAdminURL localCaddyAdminURL would have set in the real server.
	s.client = &http.Client{Timeout: time.Second}
	s.caddyAdminURL = "http://127.0.0.1:0"
	// Simulate the disabled service still being loaded in launchd, e.g.
	// before install-launchd.sh has had a chance to prune its stale plist.
	s.launchdCache = []launchdService{{Name: "disabled-svc", State: "running", PID: "4242"}}
	s.launchdCacheAt = time.Now()

	services, err := s.collectServices(context.Background())
	if err != nil {
		t.Fatalf("collectServices failed: %v", err)
	}

	var disabled *serviceStatus
	for i := range services {
		if services[i].Name == "disabled-svc" {
			disabled = &services[i]
		}
	}
	if disabled == nil {
		t.Fatal("disabled service must still be inventoried")
	}
	if disabled.OverallState != "disabled" {
		t.Fatalf("expected OverallState \"disabled\", got %q", disabled.OverallState)
	}
	if disabled.Port != nil || disabled.Route != nil || disabled.HTTP != nil {
		t.Fatalf("disabled service must not run port/route/http checks, got %+v", disabled)
	}
	if disabled.Launchd == nil || disabled.Launchd.State != "running" {
		t.Fatalf("disabled-but-still-loaded service must surface its launchd state, got %+v", disabled.Launchd)
	}
	if len(disabled.Actions) != 1 || disabled.Actions[0].ID != "service.stop" {
		t.Fatalf("disabled-but-still-loaded managed service should expose exactly service.stop, got %+v", disabled.Actions)
	}
}
