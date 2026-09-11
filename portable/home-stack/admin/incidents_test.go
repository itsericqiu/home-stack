package main

import "testing"

func TestDeriveIncidentsPrioritizesHTTPFailure(t *testing.T) {
	services := []serviceStatus{{
		Name:         "opencode",
		DisplayName:  "OpenCode",
		OverallState: "degraded",
		Launchd:      &launchdStatus{State: "running"},
		Port:         &checkStatus{OK: true, State: "open", Target: "127.0.0.1:31496"},
		Route:        &checkStatus{OK: true, State: "present"},
		HTTP:         &checkStatus{OK: false, State: "failing", Details: "timeout"},
	}}

	incidents := deriveIncidents(services)
	if len(incidents) != 1 {
		t.Fatalf("expected one incident, got %+v", incidents)
	}
	if incidents[0].Severity != "warning" || incidents[0].Service != "opencode" {
		t.Fatalf("unexpected incident: %+v", incidents[0])
	}
	if incidents[0].RecommendedActions[0] != "service.restart" {
		t.Fatalf("expected restart recommendation, got %+v", incidents[0].RecommendedActions)
	}
}

func TestOverallStateFromIncidents(t *testing.T) {
	if got := overallStateFromIncidents(nil); got != "healthy" {
		t.Fatalf("empty incidents should be healthy, got %s", got)
	}
	if got := overallStateFromIncidents([]incident{{Severity: "warning"}}); got != "degraded" {
		t.Fatalf("warning incidents should be degraded, got %s", got)
	}
	if got := overallStateFromIncidents([]incident{{Severity: "critical"}}); got != "down" {
		t.Fatalf("critical incidents should be down, got %s", got)
	}
}

func TestDeriveIncidentsTreatsScheduledTasksAsInfo(t *testing.T) {
	services := []serviceStatus{{
		Name:    "logrotate",
		Desired: &Service{Type: "task", Kind: "scheduled"},
		Launchd: &launchdStatus{State: "spawn scheduled"},
	}}

	incidents := deriveIncidents(services)
	if len(incidents) != 1 {
		t.Fatalf("expected one incident, got %+v", incidents)
	}
	if incidents[0].Severity != "info" {
		t.Fatalf("scheduled task should be informational, got %+v", incidents[0])
	}
	if got := overallStateFromIncidents(incidents); got != "healthy" {
		t.Fatalf("info-only incidents should not degrade stack, got %s", got)
	}
}

func TestDeriveIncidentsTreatsDevAndTestingServicesAsInfo(t *testing.T) {
	services := []serviceStatus{
		{
			Name:    "dev-gateway",
			Desired: &Service{Kind: "ingress", Type: "proxy", Host: "*.dev.home.example.com"},
			Route:   &checkStatus{OK: false, State: "missing"},
		},
		{
			Name:    "test-app",
			Desired: &Service{Kind: "testing", Type: "proxy"},
			Port:    &checkStatus{OK: false, Target: "127.0.0.1:9999"},
		},
	}

	incidents := deriveIncidents(services)
	if len(incidents) != 2 {
		t.Fatalf("expected two incidents, got %+v", incidents)
	}
	for _, inc := range incidents {
		if inc.Severity != "info" {
			t.Fatalf("optional service incident should be informational, got %+v", inc)
		}
	}
	if got := overallStateFromIncidents(incidents); got != "healthy" {
		t.Fatalf("optional-only incidents should not degrade stack, got %s", got)
	}
}

func TestCountServiceStatesNormalizesLegacyStateNames(t *testing.T) {
	counts := countServiceStates([]serviceStatus{{OverallState: "ok"}, {OverallState: "warn"}, {OverallState: "down"}, {OverallState: "mystery"}})
	if counts["healthy"] != 1 || counts["degraded"] != 1 || counts["down"] != 1 || counts["unknown"] != 1 {
		t.Fatalf("unexpected normalized counts: %+v", counts)
	}
}

// A disabled service was never meant to run: every check on it would report
// failure for a reason that is not an incident, so it must be skipped
// entirely rather than surfaced as critical or unknown.
func TestDeriveIncidentsSkipsDisabledServices(t *testing.T) {
	services := []serviceStatus{{
		Name:         "disabled-svc",
		OverallState: "disabled",
		Desired:      &Service{Type: "proxy"},
		// These would each independently produce an incident if not skipped.
		Launchd: &launchdStatus{State: "not loaded"},
		Port:    &checkStatus{OK: false, Target: "127.0.0.1:31999"},
	}}
	if incidents := deriveIncidents(services); len(incidents) != 0 {
		t.Fatalf("disabled service must produce no incidents, got %+v", incidents)
	}
}

// A service flipped to enabled: false stays bootstrapped (and, for a service
// like Hermes that binds the Tailnet IP directly, reachable) until
// install-launchd.sh prunes its stale plist. That is worth telling the
// operator about -- as an info incident, not a critical one -- so it does
// not sit invisible behind a neutral "disabled" card.
func TestDeriveIncidentsFlagsDisabledButStillLoadedService(t *testing.T) {
	services := []serviceStatus{{
		Name:         "disabled-svc",
		DisplayName:  "Disabled",
		OverallState: "disabled",
		Launchd:      &launchdStatus{State: "running"},
	}}
	incidents := deriveIncidents(services)
	if len(incidents) != 1 {
		t.Fatalf("expected one incident for a disabled-but-running service, got %+v", incidents)
	}
	inc := incidents[0]
	if inc.Severity != "info" {
		t.Fatalf("disabled-but-loaded should be informational, not %q", inc.Severity)
	}
	if len(inc.RecommendedActions) != 1 || inc.RecommendedActions[0] != "service.stop" {
		t.Fatalf("expected service.stop as the recommended action, got %+v", inc.RecommendedActions)
	}
	if got := overallStateFromIncidents(incidents); got != "healthy" {
		t.Fatalf("an info-only incident must not degrade the stack, got %s", got)
	}
}

func TestCountServiceStatesCountsDisabled(t *testing.T) {
	counts := countServiceStates([]serviceStatus{{OverallState: "disabled"}, {OverallState: "disabled"}, {OverallState: "healthy"}})
	if counts["disabled"] != 2 || counts["healthy"] != 1 {
		t.Fatalf("unexpected counts: %+v", counts)
	}
}
