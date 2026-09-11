package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var actionRegistry = map[string]actionDescriptor{
	// The three service.* actions have no static AllowedTargets: their
	// targets are derived from the registry via serviceOperations, so a
	// service added to services.yaml is operable without touching this file.
	"service.start": {
		ID:                   "service.start",
		Label:                "Start service",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Starts a launchd-managed service",
	},
	"service.stop": {
		ID:                   "service.stop",
		Label:                "Stop service",
		Risk:                 "destructive",
		RequiresConfirmation: true,
		ExpectedEffect:       "Stops a launchd-managed service",
	},
	"service.restart": {
		ID:                   "service.restart",
		Label:                "Restart service",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Restarts a launchd-managed service",
	},
	"caddy.validate": {
		ID:                   "caddy.validate",
		Label:                "Validate Caddy",
		Risk:                 "safe",
		RequiresConfirmation: false,
		ExpectedEffect:       "Renders and validates the Caddyfile",
		AllowedTargets:       []string{"caddy"},
	},
	"caddy.reload": {
		ID:                   "caddy.reload",
		Label:                "Reload Caddy",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Reloads Caddy configuration without restarting the daemon",
		AllowedTargets:       []string{"caddy"},
	},
	"admin.restart": {
		ID:                   "admin.restart",
		Label:                "Restart Admin",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Restarts this admin service; the webapp will reconnect",
		AllowedTargets:       []string{"admin"},
	},
	"deploy.preview": {
		ID:                   "deploy.preview",
		Label:                "Preview Changes",
		Risk:                 "safe",
		RequiresConfirmation: false,
		ExpectedEffect:       "Shows what would change before applying",
		AllowedTargets:       []string{"system"},
	},
	"deploy.apply": {
		ID:                   "deploy.apply",
		Label:                "Apply Changes",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Regenerates Caddyfile, plists, and reloads Caddy",
		AllowedTargets:       []string{"system"},
	},
	"registry.add": {
		ID:                   "registry.add",
		Label:                "Add Service",
		Risk:                 "caution",
		RequiresConfirmation: true,
		ExpectedEffect:       "Adds or updates a service in the registry",
		AllowedTargets:       []string{"system"},
	},
	"registry.remove": {
		ID:                   "registry.remove",
		Label:                "Remove Service",
		Risk:                 "destructive",
		RequiresConfirmation: true,
		ExpectedEffect:       "Removes a service from the registry",
		AllowedTargets:       []string{"system"},
	},
}

func actionByID(id string) (actionDescriptor, bool) {
	desc, ok := actionRegistry[id]
	return desc, ok
}

// serviceOperations returns the launchd operations the admin may perform on a
// service, derived from its registry entry rather than a hardcoded list.
// Policy:
//   - enabled: false, lifecycle "managed": stop only. The engine no longer
//     generates a plist for it, but a service that was running before the
//     operator disabled it can stay bootstrapped (and reachable — Hermes
//     binds the Tailnet IP directly) until install-launchd.sh prunes it, so
//     stop is the one operation that still makes sense; start/restart would
//     fight the operator's own decision to disable it. (Validate forbids
//     disabling type: system or the admin service itself, so those two
//     special cases below never coincide with a disabled entry in practice.)
//   - enabled: false, otherwise: no operations — there was never a plist for
//     these lifecycles to begin with.
//   - type "system" (caddy): reload only — stop/restart stay CLI-only
//   - "admin" itself: restart only — stopping it from its own UI would strand
//     the operator; it is home-stack's own service, so lifecycle is implied
//   - lifecycle "managed": home-stack owns the plist → operable; scheduled
//     tasks get start/restart but no stop (they exit on their own)
//   - lifecycle "external", "custom", or unset: route-only (custom plists are
//     Phase F's problem)
func serviceOperations(name string, svc Service) map[string]bool {
	if !svc.IsEnabled() {
		if svc.Lifecycle == "managed" {
			return map[string]bool{"stop": true}
		}
		return nil
	}
	if svc.Type == "system" {
		return map[string]bool{"reload": true}
	}
	if name == "admin" {
		return map[string]bool{"restart": true}
	}
	if svc.Lifecycle != "managed" {
		return nil
	}
	if svc.IsScheduledTask() {
		return map[string]bool{"start": true, "restart": true}
	}
	return map[string]bool{"start": true, "stop": true, "restart": true}
}

// serviceActionID maps a launchd operation to its typed action descriptor.
var serviceActionID = map[string]string{
	"start":   "service.start",
	"stop":    "service.stop",
	"restart": "service.restart",
	"reload":  "caddy.reload",
}

// actionsForService lists the typed actions available for a service, in a
// stable order, derived from serviceOperations. serviceOperations is nil (or
// empty) exactly when there is nothing to offer -- including for a disabled
// service with no managed lifecycle -- so checking its length is sufficient;
// for an enabled system or admin entry it always returns a non-nil op, so
// this stays behaviour-equivalent to the old explicit IsEnabled guard there.
func actionsForService(name string, svc Service) []actionDescriptor {
	ops := serviceOperations(name, svc)
	if len(ops) == 0 {
		return nil
	}
	var result []actionDescriptor
	for _, op := range []string{"start", "stop", "restart", "reload"} {
		if ops[op] {
			result = append(result, actionRegistry[serviceActionID[op]])
		}
	}
	if svc.Type == "system" {
		result = append([]actionDescriptor{actionRegistry["caddy.validate"]}, result...)
	}
	if name == "admin" {
		result = append(result, actionRegistry["admin.restart"])
	}
	return result
}

// targetAllowed checks a requested action/target pair. The three service.*
// actions consult the registry (the same derivation the UI buttons come
// from); the remaining actions have fixed, non-service targets and keep
// their static allowlists.
func (s *server) targetAllowed(desc actionDescriptor, target string) bool {
	switch desc.ID {
	case "service.start", "service.stop", "service.restart":
		reg, err := s.loadActiveRegistry()
		if err != nil {
			return false
		}
		svc, ok := reg.Services[target]
		if !ok {
			return false
		}
		op := strings.TrimPrefix(desc.ID, "service.")
		return serviceOperations(target, svc)[op]
	default:
		for _, allowed := range desc.AllowedTargets {
			if allowed == target {
				return true
			}
		}
		return false
	}
}

func (s *server) validateActionRequest(req actionRequest) error {
	desc, ok := actionByID(req.Action)
	if !ok {
		return fmt.Errorf("unknown action %q", req.Action)
	}
	if !s.targetAllowed(desc, req.Target) {
		return fmt.Errorf("target %q is not allowed for %s", req.Target, req.Action)
	}
	if desc.RequiresConfirmation && !req.Confirm {
		return fmt.Errorf("action %s requires confirmation", req.Action)
	}
	return nil
}

func (s *server) executeAction(ctx context.Context, actor string, req actionRequest) actionResult {
	start := time.Now()
	desc, _ := actionByID(req.Action)
	result := actionResult{OK: true, Message: fmt.Sprintf("%s completed", desc.Label)}
	var out string
	var err error

	switch req.Action {
	case "service.start", "service.stop", "service.restart":
		parts := map[string]string{"service.start": "start", "service.stop": "stop", "service.restart": "restart"}
		out, err = s.runServiceAction(ctx, req.Target, parts[req.Action])
	case "caddy.validate":
		if out, err = s.syncSystem(); err == nil {
			out, err = s.run(ctx, filepath.Join(s.bundleDir, "bin", "caddy-cloudflare"), "validate", "--config", filepath.Join(s.bundleDir, "Caddyfile"))
		}
	case "caddy.reload":
		out, err = s.run(ctx, filepath.Join(s.bundleDir, "scripts", "reload-caddy.sh"))
	case "admin.restart":
		out, err = s.runServiceAction(ctx, "admin", "restart")
	case "deploy.preview":
		out, err = s.deployPreviewAction()
	case "deploy.apply":
		out, err = s.deployApplyAction(ctx)
	case "registry.add":
		out, err = s.registryAddAction(req)
	case "registry.remove":
		out, err = s.registryRemoveAction(req)
	}

	if err != nil {
		result.OK = false
		result.Message = fmt.Sprintf("%s failed", desc.Label)
		result.Cause = err.Error()
		if req.Action != "deploy.preview" {
			out = redactOutput(out)
		}
		result.Details = out
		result.NextActions = []string{"events.open", "doctor.open"}
	} else if out != "" {
		// Store action output for success cases (e.g., deploy preview diff)
		if req.Action != "deploy.preview" {
			out = redactOutput(out)
		}
		result.Details = out
	}
	result.EventID = fmt.Sprintf("evt_%d_%s_%s", time.Now().Unix(), req.Target, req.Action)
	if auditErr := s.appendEvent(adminEvent{ID: result.EventID, Time: time.Now(), Actor: actor, Action: req.Action, Target: req.Target, Risk: desc.Risk, OK: result.OK, Message: result.Message, Details: result.Details, Duration: time.Since(start).String()}); auditErr != nil {
		result.OK = false
		result.Message = "action audit failed"
		result.Cause = auditErr.Error()
		result.Details = "The requested action ran, but the admin event log could not be written. Check HOME_STACK_CONFIG_DIR permissions."
		result.NextActions = []string{"doctor.open"}
	}
	return result
}

func (s *server) deployPreviewAction() (string, error) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	diff, err := Diff(s.bundleDir, profile)
	if err != nil {
		return "", err
	}
	diffJSON, _ := json.Marshal(diff)
	return string(diffJSON), nil
}

func (s *server) deployApplyAction(ctx context.Context) (string, error) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	syncOut, err := Apply(s.bundleDir, profile)
	if err != nil {
		return "", fmt.Errorf("apply failed: %w\n%s", err, syncOut)
	}
	out, err := s.run(ctx, filepath.Join(s.bundleDir, "scripts", "reload-caddy.sh"))
	if err != nil {
		return fmt.Sprintf("%s\nreload failed: %s", syncOut, out), err
	}
	return syncOut, nil
}

func (s *server) registryAddAction(req actionRequest) (string, error) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	if err := AddService(s.bundleDir, profile, req.Target, req.Service); err != nil {
		return "", err
	}
	return fmt.Sprintf("Service %q added to registry", req.Target), nil
}

func (s *server) registryRemoveAction(req actionRequest) (string, error) {
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" {
		profile = os.Getenv("USER")
	}
	if err := RemoveService(s.bundleDir, profile, req.Target); err != nil {
		return "", err
	}
	return fmt.Sprintf("Service %q removed from registry", req.Target), nil
}

func countChanges(diff *DeployDiff) int {
	return diff.Caddyfile.Added + diff.Caddyfile.Removed + diff.Caddyfile.Changed +
		diff.Launchd.Added + diff.Launchd.Removed + diff.Launchd.Changed +
		diff.Catalog.Added + diff.Catalog.Removed + diff.Catalog.Changed
}
