package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var secretPattern = regexp.MustCompile(`(?i)(token|password|secret|api[_-]?key|key)(\s*[:=]\s*|"\s*:\s*")([^\s,"'}]+)`)

func redactOutput(s string) string {
	s = secretPattern.ReplaceAllString(s, "$1$2[REDACTED]")
	for _, key := range []string{"HOME_STACK_ADMIN_PASSWORD", "HOME_STACK_CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_TOKEN"} {
		if value := os.Getenv(key); value != "" {
			s = strings.ReplaceAll(s, value, "[REDACTED]")
		}
	}
	if len(s) > 800 {
		return s[:800] + "…"
	}
	return s
}

func (s *server) eventPath() string {
	configDir := os.Getenv("HOME_STACK_CONFIG_DIR")
	if configDir == "" {
		home := os.Getenv("HOME")
		if home == "" {
			return filepath.Join(os.TempDir(), "home-stack", "admin-events.jsonl")
		}
		configDir = filepath.Join(home, ".config", "home-stack")
	}
	return filepath.Join(configDir, "admin-events.jsonl")
}

func (s *server) appendEvent(evt adminEvent) error {
	if evt.Time.IsZero() {
		evt.Time = time.Now()
	}
	evt.Details = redactOutput(evt.Details)
	path := s.eventPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	line, err := json.Marshal(evt)
	if err != nil {
		return err
	}
	_, err = f.Write(append(line, '\n'))
	return err
}

func (s *server) readEvents(limit int) ([]adminEvent, error) {
	path := s.eventPath()
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var events []adminEvent
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var evt adminEvent
		if err := json.Unmarshal(scanner.Bytes(), &evt); err == nil {
			evt.Details = redactOutput(evt.Details)
			events = append(events, evt)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(events)-1; i < j; i, j = i+1, j-1 {
		events[i], events[j] = events[j], events[i]
	}
	if limit > 0 && len(events) > limit {
		events = events[:limit]
	}
	return events, nil
}
