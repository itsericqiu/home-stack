package main

import (
	"net/url"
	"os"
	"path/filepath"
)

func (s *server) doctorChecks() []doctorCheck {
	checks := []doctorCheck{}
	if s.adminPassword == "" {
		checks = append(checks, doctorCheck{ID: "admin-password", Label: "Admin password configured", State: "fail", Details: "HOME_STACK_ADMIN_PASSWORD is empty"})
	} else {
		checks = append(checks, doctorCheck{ID: "admin-password", Label: "Admin password configured", State: "ok"})
	}

	state := "fail"
	details := s.caddyAdminURL
	if u, err := url.Parse(s.caddyAdminURL); err == nil && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost" || u.Hostname() == "::1") {
		state = "ok"
	}
	checks = append(checks, doctorCheck{ID: "caddy-admin-loopback", Label: "Caddy Admin API loopback-only", State: state, Details: details})

	if _, err := os.Stat(filepath.Join(s.bundleDir, "bin", "caddy-cloudflare")); err == nil {
		checks = append(checks, doctorCheck{ID: "caddy-binary", Label: "Caddy Cloudflare binary exists", State: "ok"})
	} else {
		checks = append(checks, doctorCheck{ID: "caddy-binary", Label: "Caddy Cloudflare binary exists", State: "warn", Details: err.Error()})
	}
	return checks
}
