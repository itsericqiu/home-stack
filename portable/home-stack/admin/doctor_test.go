package main

import "testing"

func TestDoctorMarksLoopbackCaddyAdminHealthy(t *testing.T) {
	s := &server{caddyAdminURL: "http://127.0.0.1:2019", adminPassword: "set"}
	checks := s.doctorChecks()
	if len(checks) == 0 {
		t.Fatal("expected checks")
	}
	if stateForCheck(checks, "caddy-admin-loopback") != "ok" {
		t.Fatalf("expected loopback check ok: %+v", checks)
	}
}

func TestDoctorFlagsNonLoopbackCaddyAdmin(t *testing.T) {
	s := &server{caddyAdminURL: "http://example.com:2019", adminPassword: "set"}
	checks := s.doctorChecks()
	if stateForCheck(checks, "caddy-admin-loopback") != "fail" {
		t.Fatalf("expected loopback check fail: %+v", checks)
	}
}

func stateForCheck(checks []doctorCheck, id string) string {
	for _, check := range checks {
		if check.ID == id {
			return check.State
		}
	}
	return "missing"
}
