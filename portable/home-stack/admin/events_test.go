package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRedactOutputRemovesSecretPatternsAndBoundsLength(t *testing.T) {
	input := "token=abcdef password=hunter2 " + strings.Repeat("x", 2000)
	out := redactOutput(input)
	if strings.Contains(out, "abcdef") || strings.Contains(out, "hunter2") {
		t.Fatalf("redaction leaked secret: %q", out)
	}
	if len(out) > 900 {
		t.Fatalf("redaction should bound output length, got %d", len(out))
	}
}

func TestAppendAndReadEvents(t *testing.T) {
	t.Setenv("HOME_STACK_CONFIG_DIR", "")
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	s := &server{bundleDir: dir, adminUsername: "admin"}
	evt := adminEvent{ID: "evt_test", Time: time.Now(), Actor: "admin", Action: "caddy.validate", Risk: "safe", OK: true, Message: "validated", Details: "token=abcdef"}
	if err := s.appendEvent(evt); err != nil {
		t.Fatal(err)
	}
	events, err := s.readEvents(5)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].ID != "evt_test" {
		t.Fatalf("unexpected events: %+v", events)
	}
	if strings.Contains(events[0].Details, "abcdef") {
		t.Fatalf("stored event was not redacted: %+v", events[0])
	}
	if _, err := os.Stat(filepath.Join(dir, ".config", "home-stack", "admin-events.jsonl")); err != nil {
		t.Fatalf("expected event file: %v", err)
	}
}
