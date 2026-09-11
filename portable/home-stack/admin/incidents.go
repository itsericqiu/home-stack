package main

import "fmt"

func deriveIncidents(services []serviceStatus) []incident {
	var out []incident
	for _, svc := range services {
		name := svc.Name
		label := svc.DisplayName
		if label == "" {
			label = name
		}

		if svc.OverallState == "disabled" {
			// A disabled service was never meant to run, so none of the
			// checks below apply to it — except this one: if it is still
			// loaded (bootstrapped before the operator flipped
			// enabled: false, and not yet pruned by install-launchd.sh) it
			// may still be occupying a port or binding a host directly
			// (Hermes binds the Tailnet IP itself), so the operator should
			// be told to prune it rather than assume disabling it was enough.
			if svc.Launchd != nil && svc.Launchd.State == "running" {
				out = append(out, incident{
					ID:                 fmt.Sprintf("%s-disabled-loaded", name),
					Severity:           "info",
					Service:            name,
					Title:              fmt.Sprintf("%s is disabled but still loaded", label),
					Explanation:        "run install-launchd.sh to prune its stale plist",
					Confidence:         "high",
					RecommendedActions: []string{"service.stop"},
				})
			}
			continue
		}

		optional := isOptionalService(svc)
		if svc.Launchd != nil && svc.Launchd.State != "" && svc.Launchd.State != "running" {
			severity := "critical"
			if optional {
				severity = "info"
			}
			out = append(out, incident{
				ID:                 fmt.Sprintf("%s-launchd", name),
				Severity:           severity,
				Service:            name,
				Title:              fmt.Sprintf("%s is not running", label),
				Explanation:        fmt.Sprintf("launchd reports state %q", svc.Launchd.State),
				Confidence:         "high",
				RecommendedActions: []string{"service.restart", "doctor.open"},
			})
			continue
		}

		if svc.Port != nil && !svc.Port.OK {
			severity := "critical"
			if optional {
				severity = "info"
			}
			out = append(out, incident{
				ID:                 fmt.Sprintf("%s-port", name),
				Severity:           severity,
				Service:            name,
				Title:              fmt.Sprintf("%s port is closed", label),
				Explanation:        fmt.Sprintf("port check failed for %s", svc.Port.Target),
				Confidence:         "high",
				RecommendedActions: []string{"service.restart", "events.open"},
			})
			continue
		}

		if svc.Route != nil && !svc.Route.OK {
			severity := "warning"
			if optional {
				severity = "info"
			}
			out = append(out, incident{
				ID:                 fmt.Sprintf("%s-route", name),
				Severity:           severity,
				Service:            name,
				Title:              fmt.Sprintf("%s route is missing", label),
				Explanation:        "Caddy runtime config does not show the expected route",
				Confidence:         "medium",
				RecommendedActions: []string{"caddy.validate", "caddy.reload"},
			})
			continue
		}

		if svc.HTTP != nil && !svc.HTTP.OK {
			severity := "warning"
			if optional {
				severity = "info"
			}
			out = append(out, incident{
				ID:                 fmt.Sprintf("%s-http", name),
				Severity:           severity,
				Service:            name,
				Title:              fmt.Sprintf("%s HTTP probe is failing", label),
				Explanation:        svc.HTTP.Details,
				Confidence:         "medium",
				RecommendedActions: []string{"service.restart", "events.open"},
			})
		}
	}
	return out
}

func overallStateFromIncidents(incidents []incident) string {
	state := "healthy"
	for _, inc := range incidents {
		if inc.Severity == "critical" {
			return "down"
		}
		if inc.Severity == "warning" {
			state = "degraded"
		}
	}
	return state
}

func isOptionalService(svc serviceStatus) bool {
	if svc.Desired == nil {
		return false
	}
	return svc.Desired.Type == "task" || svc.Desired.Kind == "scheduled" || svc.Desired.Kind == "testing" || svc.Name == "dev-gateway"
}

func countServiceStates(services []serviceStatus) map[string]int {
	counts := map[string]int{"healthy": 0, "degraded": 0, "down": 0, "unknown": 0, "disabled": 0}
	for _, svc := range services {
		switch svc.OverallState {
		case "healthy", "ok":
			counts["healthy"]++
		case "degraded", "warn":
			counts["degraded"]++
		case "down":
			counts["down"]++
		case "disabled":
			counts["disabled"]++
		default:
			counts["unknown"]++
		}
	}
	return counts
}
