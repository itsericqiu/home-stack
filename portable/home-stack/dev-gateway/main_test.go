package main

import "testing"

// IsEnabled mirrors the admin engine's Service.IsEnabled: absent (nil) means
// enabled, so a registry entry written before enabled: existed keeps being
// proxied without edits.
func TestIsEnabledDefaultsTrueWhenAbsent(t *testing.T) {
	var svc Service
	if !svc.IsEnabled() {
		t.Fatal("a service with no enabled field must default to enabled")
	}
	disabled := false
	svc.Enabled = &disabled
	if svc.IsEnabled() {
		t.Fatal("enabled: false must be respected")
	}
	enabled := true
	svc.Enabled = &enabled
	if !svc.IsEnabled() {
		t.Fatal("enabled: true must be respected")
	}
}
