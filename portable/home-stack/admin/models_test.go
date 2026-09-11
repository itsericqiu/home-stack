package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSanitizedServiceOmitsSecretBearingFields(t *testing.T) {
	svc := Service{
		DisplayName:   "Secret App",
		Kind:          "app",
		Type:          "proxy",
		Host:          "secret.home.example.com",
		Upstream:      "127.0.0.1:3000",
		ProxyIdentity: "upstream",
		Binary:        "/bin/example",
		Args:          []string{"--token=secret"},
		Env:           map[string]string{"TOKEN": "secret"},
	}

	out := sanitizeDesiredService(svc)
	body, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}

	if strings.Contains(string(body), "TOKEN") || strings.Contains(string(body), "--token=secret") || strings.Contains(string(body), "Args") || strings.Contains(string(body), "Env") {
		t.Fatalf("sanitized service leaked secret-bearing fields: %s", body)
	}
	if out.DisplayName != "Secret App" || out.Host != "secret.home.example.com" || out.Upstream != "127.0.0.1:3000" {
		t.Fatalf("sanitized service lost safe fields: %+v", out)
	}
	if out.ProxyIdentity != "upstream" {
		t.Fatalf("sanitized service lost safe proxy identity: %+v", out)
	}
}
