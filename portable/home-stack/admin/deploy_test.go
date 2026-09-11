package main

import "testing"

func TestDeployPreviewRedactsGeneratedSecretFields(t *testing.T) {
	t.Setenv("HOME_STACK_PARENT_DOMAIN", "home.example.com")
	r := &Registry{Services: map[string]Service{"app": {Type: "proxy", Subdomain: "app", Upstream: "127.0.0.1:3000", Env: map[string]string{"TOKEN": "secret"}}}}
	preview := buildDeployPreview(r)
	if !preview.OK || !preview.Valid {
		t.Fatalf("expected valid preview: %+v", preview)
	}
	for _, changed := range preview.ChangedFiles {
		if changed == "secret" || changed == "TOKEN" {
			t.Fatalf("preview leaked secret token: %+v", preview)
		}
	}
}
