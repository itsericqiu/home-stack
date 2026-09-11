package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestGenerateCaddyfileDoesNotEmbedCloudflareSecret(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"admin": {
			DisplayName: "Admin",
			Type:        "proxy",
			Subdomain:   "admin",
			Upstream:    "127.0.0.1:31510",
		},
	}}

	caddyfile := r.GenerateCaddyfile("admin@example.com", "100.64.0.8", "/Users/test", "home.example.com")

	if strings.Contains(caddyfile, "secret-token") {
		t.Fatalf("generated Caddyfile embedded Cloudflare token: %s", caddyfile)
	}
	if !strings.Contains(caddyfile, "dns cloudflare {env.CLOUDFLARE_API_TOKEN}") {
		t.Fatalf("generated Caddyfile should reference env token, got: %s", caddyfile)
	}
}

func TestGenerateLaunchdPlistEscapesXMLValues(t *testing.T) {
	r := &Registry{}
	svc := Service{
		Binary:     "/bin/echo",
		Args:       []string{"hello & <world>"},
		WorkingDir: "/tmp/a&b",
		Env:        map[string]string{"SAFE_KEY": "one & <two>"},
	}

	plist, err := r.GenerateLaunchdPlist("demo", svc, "testprof", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if err != nil {
		t.Fatalf("GenerateLaunchdPlist: %v", err)
	}

	for _, raw := range []string{"hello & <world>", "/tmp/a&b", "one & <two>"} {
		if strings.Contains(plist, raw) {
			t.Fatalf("plist contains unescaped XML value %q: %s", raw, plist)
		}
	}
	if !strings.Contains(plist, "hello &amp; &lt;world&gt;") {
		t.Fatalf("plist did not escape argument: %s", plist)
	}
}

func TestGenerateLaunchdPlistSchedulesTasksInsteadOfKeepAlive(t *testing.T) {
	r := &Registry{}

	daemon, errDaemon := r.GenerateLaunchdPlist("openchamber", Service{Type: "proxy"}, "testprof", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if errDaemon != nil {
		t.Fatalf("generate: %v", errDaemon)
	}
	if !strings.Contains(daemon, "<key>KeepAlive</key>") {
		t.Fatalf("long-running service should be KeepAlive: %s", daemon)
	}
	if strings.Contains(daemon, "<key>StartInterval</key>") {
		t.Fatalf("long-running service should not be scheduled: %s", daemon)
	}

	task, errTask := r.GenerateLaunchdPlist("logrotate", Service{Kind: "scheduled", Type: "task", Interval: 900}, "testprof", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if errTask != nil {
		t.Fatalf("generate: %v", errTask)
	}
	if strings.Contains(task, "<key>KeepAlive</key>") {
		t.Fatalf("scheduled task must not use KeepAlive, it would respawn in a loop: %s", task)
	}
	if !strings.Contains(task, "<key>StartInterval</key>\n\t<integer>900</integer>") {
		t.Fatalf("scheduled task did not honour interval_seconds: %s", task)
	}

	defaulted, errDefaulted := r.GenerateLaunchdPlist("logrotate", Service{Type: "task"}, "testprof", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if errDefaulted != nil {
		t.Fatalf("generate: %v", errDefaulted)
	}
	if !strings.Contains(defaulted, "<integer>3600</integer>") {
		t.Fatalf("scheduled task without interval_seconds should default to hourly: %s", defaulted)
	}
}

func TestGenerateSystemDaemonPlist(t *testing.T) {
	r := &Registry{}
	plist, errPlist := r.GenerateSystemDaemonPlist("caddy", Service{Type: "system"}, "testprof", "/bundle", "/Users/test", "io.example")
	if errPlist != nil {
		t.Fatalf("generate: %v", errPlist)
	}

	for _, want := range []string{
		"<string>io.example.home-stack.caddy</string>",
		"<string>/bundle/scripts/run-caddy.sh</string>",
		"<key>ThrottleInterval</key>",
		"<key>KeepAlive</key>",
		"<key>XDG_DATA_HOME</key>",
		"<string>/Users/test/.config/home-stack/caddy/data</string>",
		"/Users/test/.config/home-stack/logs/caddy.launchd.err.log",
	} {
		if !strings.Contains(plist, want) {
			t.Errorf("daemon plist missing %q:\n%s", want, plist)
		}
	}
	if strings.Contains(plist, "StartInterval") {
		t.Errorf("daemon plist must not be scheduled: %s", plist)
	}
}

func TestValidateRegistryRejectsUnsafeServiceDefinitions(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"bad name": {Type: "proxy", Host: "bad.home.example.com", Upstream: "127.0.0.1:31510"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected invalid service name to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"badhost": {Type: "proxy", Host: "bad.home.example.com\nrespond hacked", Upstream: "127.0.0.1:31510"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected host with newline to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"bad-env": {Type: "proxy", Subdomain: "bad", Upstream: "127.0.0.1:31510", Env: map[string]string{"BAD-KEY": "value"}},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected unsafe env key to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"bad-upstream": {Type: "proxy", Subdomain: "bad", Upstream: "127.0.0.1:31510 respond hacked"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected upstream with whitespace to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"bad-static": {Type: "static", Subdomain: "bad"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected static service without root to be rejected")
	}
}

func TestValidateRegistryAcceptsCoreServiceShape(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"admin":  {DisplayName: "Admin", Kind: "control", Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510", Health: HealthConfig{Port: 31510}},
		"portal": {DisplayName: "Portal", Kind: "static", Type: "static", Subdomain: "portal", Root: "~/github/home-portal/dist"},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("expected valid registry, got: %v", err)
	}

	// Split type — valid
	r = &Registry{Services: map[string]Service{
		"myapp": {Type: "split", Subdomain: "myapp", Root: "~/myapp/dist", Upstream: "127.0.0.1:3000", APIPath: "/api"},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("expected valid split service, got: %v", err)
	}

	// Split type — invalid (missing subdomain)
	r = &Registry{Services: map[string]Service{
		"bad-split": {Type: "split", Root: "~/dist", Upstream: "127.0.0.1:3000"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected split without subdomain or host to be rejected")
	}
}

func TestValidateEnvMissingFails(t *testing.T) {
	allVars := []string{
		"HOME_STACK_PARENT_DOMAIN",
		"HOME_STACK_TAILNET_IP",
		"HOME_STACK_ACME_EMAIL",
		"HOME_STACK_OWNER_HOME",
		"HOME_STACK_IDENTIFIER_PREFIX",
		"HOME_STACK_ADMIN_USERNAME",
	}
	for _, missing := range allVars {
		t.Run(missing, func(t *testing.T) {
			// Set all vars.
			for _, k := range allVars {
				t.Setenv(k, "test-value")
			}
			// Unset the one under test.
			os.Unsetenv(missing)
			err := validateEnv()
			if err == nil {
				t.Fatalf("expected error when %s is unset, got nil", missing)
			}
			if !strings.Contains(err.Error(), missing) {
				t.Fatalf("error %q should mention missing key %q", err.Error(), missing)
			}
		})
	}
}

func TestSyncSystemMissingEnvFails(t *testing.T) {
	// Clear all mandatory env vars.
	for _, k := range []string{
		"HOME_STACK_PARENT_DOMAIN",
		"HOME_STACK_TAILNET_IP",
		"HOME_STACK_ACME_EMAIL",
		"HOME_STACK_OWNER_HOME",
		"HOME_STACK_IDENTIFIER_PREFIX",
		"HOME_STACK_ADMIN_USERNAME",
	} {
		t.Setenv(k, "")
	}
	s := &server{bundleDir: t.TempDir()}
	_, err := s.syncSystem()
	if err == nil {
		t.Fatal("expected error when mandatory env vars are missing")
	}
}

func TestRegistryValidateSubdomainHost(t *testing.T) {
	parent := "home.example.com"
	cases := []struct {
		name    string
		svc     Service
		wantErr bool
	}{
		{
			name:    "subdomain ok",
			svc:     Service{Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510"},
			wantErr: false,
		},
		{
			name:    "wildcard subdomain ok",
			svc:     Service{Type: "proxy", Subdomain: "*", Upstream: "127.0.0.1:31510"},
			wantErr: false,
		},
		{
			name:    "wildcard sub-subdomain ok",
			svc:     Service{Type: "proxy", Subdomain: "*.dev", Upstream: "127.0.0.1:31510"},
			wantErr: false,
		},
		{
			name:    "external host ok",
			svc:     Service{Type: "proxy", Host: "external.other.com", Upstream: "127.0.0.1:31510"},
			wantErr: false,
		},
		{
			name:    "host overlaps parent rejected",
			svc:     Service{Type: "proxy", Host: "portal.home.example.com", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "both subdomain and host rejected",
			svc:     Service{Type: "proxy", Subdomain: "admin", Host: "other.example.com", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "proxy with neither is internal-only and ok",
			svc:     Service{Type: "proxy", Upstream: "127.0.0.1:31510"},
			wantErr: false,
		},
		{
			name:    "static with neither rejected",
			svc:     Service{Type: "static", Root: "/tmp/x"},
			wantErr: true,
		},
		{
			name:    "missing type rejected",
			svc:     Service{Subdomain: "admin"},
			wantErr: true,
		},
		{
			name:    "proxy without upstream rejected",
			svc:     Service{Type: "proxy", Subdomain: "admin"},
			wantErr: true,
		},
		{
			name:    "static without root rejected",
			svc:     Service{Type: "static", Subdomain: "static"},
			wantErr: true,
		},
		{
			name:    "host overlapping parent exactly rejected",
			svc:     Service{Type: "proxy", Host: "home.example.com", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "host overlapping parent wildcard rejected",
			svc:     Service{Type: "proxy", Host: "*.home.example.com", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "malformed subdomain rejected (uppercase)",
			svc:     Service{Type: "proxy", Subdomain: "Admin", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "malformed subdomain rejected (leading dot)",
			svc:     Service{Type: "proxy", Subdomain: ".admin", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "malformed subdomain rejected (double asterisk)",
			svc:     Service{Type: "proxy", Subdomain: "**", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "malformed service name rejected (uppercase)",
			svc:     Service{Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "malformed service name rejected (starts with hyphen)",
			svc:     Service{Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510"},
			wantErr: true,
		},
		{
			name:    "binary with whitespace allowed (paths may contain spaces)",
			svc:     Service{Type: "task", Binary: "/usr/bin/my space"},
			wantErr: false,
		},
		{
			name:    "args with whitespace allowed (shell commands may have spaces)",
			svc:     Service{Type: "task", Args: []string{"-c", "echo hello world"}, Binary: "/bin/bash"},
			wantErr: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svcName := "svc"
			if tc.name != "" && strings.Contains(tc.name, "service name rejected") {
				// Use the descriptive name as the service name for these cases if we had a field,
				// but let's just use tc.name if it matches what we want to test.
				// Wait, the case struct doesn't have a service name field.
				// I'll adjust the loop to handle it.
			}
			r := &Registry{Services: map[string]Service{svcName: tc.svc}}
			if strings.Contains(tc.name, "service name rejected") {
				// Extract the actual service name we want to test
				if strings.Contains(tc.name, "(uppercase)") {
					r.Services = map[string]Service{"ADMIN": tc.svc}
				} else if strings.Contains(tc.name, "(starts with hyphen)") {
					r.Services = map[string]Service{"-admin": tc.svc}
				}
			}
			err := r.Validate(parent)
			if tc.wantErr && err == nil {
				t.Fatalf("expected error for case %q, got nil", tc.name)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("unexpected error for case %q: %v", tc.name, err)
			}
		})
	}
}

func TestResolvedHost(t *testing.T) {
	parent := "home.example.com"
	cases := []struct {
		svc  Service
		want string
	}{
		{Service{Subdomain: "admin"}, "admin.home.example.com"},
		{Service{Subdomain: "*"}, "*.home.example.com"},
		{Service{Subdomain: "*.dev"}, "*.dev.home.example.com"},
		{Service{Host: "external.other.com"}, "external.other.com"},
		{Service{Host: "app.example.org"}, "app.example.org"},
	}
	for _, tc := range cases {
		got := tc.svc.ResolvedHost(parent)
		if got != tc.want {
			t.Errorf("ResolvedHost(%+v) = %q; want %q", tc.svc, got, tc.want)
		}
	}
}

func TestGenerateCaddyfileSubdomain(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"admin": {
			DisplayName: "Admin",
			Type:        "proxy",
			Subdomain:   "admin",
			Upstream:    "127.0.0.1:31510",
		},
	}}
	caddyfile := r.GenerateCaddyfile("acme@example.com", "100.64.0.8", "/home/test", "home.example.com")

	if !strings.Contains(caddyfile, "host admin.home.example.com") {
		t.Fatalf("expected Caddyfile to contain 'host admin.home.example.com', got:\n%s", caddyfile)
	}
}

func TestGenerateCaddyfileUpstreamProxyIdentity(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"hermes": {
			DisplayName:   "Hermes",
			Type:          "proxy",
			Subdomain:     "hermes",
			Upstream:      "100.64.0.8:31511",
			ProxyIdentity: "upstream",
		},
	}}
	caddyfile := r.GenerateCaddyfile("acme@example.com", "100.64.0.8", "/home/test", "home.example.com")

	for _, want := range []string{
		"reverse_proxy 100.64.0.8:31511 {",
		"header_up Host {upstream_hostport}",
		"header_up Origin http://{upstream_hostport}",
	} {
		if !strings.Contains(caddyfile, want) {
			t.Fatalf("expected Caddyfile to contain %q, got:\n%s", want, caddyfile)
		}
	}
}

func TestValidateRegistryRejectsInvalidProxyIdentity(t *testing.T) {
	for name, svc := range map[string]Service{
		"unknown": {Type: "proxy", Subdomain: "demo", Upstream: "127.0.0.1:3000", ProxyIdentity: "arbitrary"},
		"static":  {Type: "static", Subdomain: "demo", Root: "/tmp/demo", ProxyIdentity: "upstream"},
	} {
		t.Run(name, func(t *testing.T) {
			r := &Registry{Services: map[string]Service{"demo": svc}}
			if err := r.Validate("home.example.com"); err == nil {
				t.Fatalf("expected proxy_identity validation failure for %+v", svc)
			}
		})
	}
}

func TestGenerateCaddyfileSplit(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"myapp": {
			DisplayName: "My App",
			Type:        "split",
			Subdomain:   "myapp",
			Root:        "/home/test/myapp/dist",
			Upstream:    "127.0.0.1:3000",
			APIPath:     "/api",
		},
	}}
	caddyfile := r.GenerateCaddyfile("split@example.com", "127.0.0.1", "/home/test", "split.test")

	if !strings.Contains(caddyfile, "host myapp.split.test") {
		t.Fatalf("expected Caddyfile to contain host matcher, got:\n%s", caddyfile)
	}
	if !strings.Contains(caddyfile, "reverse_proxy 127.0.0.1:3000") {
		t.Fatalf("expected Caddyfile to contain reverse_proxy for API, got:\n%s", caddyfile)
	}
	if !strings.Contains(caddyfile, "root \"/home/test/myapp/dist\"") {
		t.Fatalf("expected Caddyfile to contain root for static assets, got:\n%s", caddyfile)
	}
	if !strings.Contains(caddyfile, "handle /api*") {
		t.Fatalf("expected Caddyfile to contain API path handle, got:\n%s", caddyfile)
	}
	if !strings.Contains(caddyfile, "try_files") {
		t.Fatalf("expected Caddyfile to contain try_files for SPA fallback, got:\n%s", caddyfile)
	}
}

func TestRegistryRoundTrip(t *testing.T) {
	r := &Registry{
		Services: map[string]Service{
			"admin": {
				DisplayName:   "Admin",
				Kind:          "control",
				Type:          "proxy",
				Subdomain:     "admin",
				Upstream:      "127.0.0.1:31510",
				ProxyIdentity: "upstream",
				Health: HealthConfig{
					Port:    31510,
					HTTPURL: "/api/health",
				},
			},
			"static-svc": {
				DisplayName: "Static",
				Type:        "static",
				Host:        "static.example.org",
				Root:        "/var/www",
			},
			"task-svc": {
				DisplayName: "Task",
				Type:        "task",
				Binary:      "/usr/bin/task",
				Args:        []string{"--flag", "value"},
				WorkingDir:  "/tmp",
				Env:         map[string]string{"KEY": "VALUE"},
			},
		},
	}

	data, err := yaml.Marshal(r)
	if err != nil {
		t.Fatalf("failed to marshal registry: %v", err)
	}

	var r2 Registry
	if err := yaml.Unmarshal(data, &r2); err != nil {
		t.Fatalf("failed to unmarshal registry: %v", err)
	}

	// Simple check for key fields
	if len(r2.Services) != len(r.Services) {
		t.Fatalf("expected %d services, got %d", len(r.Services), len(r2.Services))
	}

	for name, svc := range r.Services {
		svc2, ok := r2.Services[name]
		if !ok {
			t.Fatalf("service %q missing in unmarshaled registry", name)
		}
		if svc2.DisplayName != svc.DisplayName {
			t.Errorf("service %q: expected DisplayName %q, got %q", name, svc.DisplayName, svc2.DisplayName)
		}
		if svc2.Type != svc.Type {
			t.Errorf("service %q: expected Type %q, got %q", name, svc.Type, svc2.Type)
		}
		if svc2.Upstream != svc.Upstream {
			t.Errorf("service %q: expected Upstream %q, got %q", name, svc.Upstream, svc2.Upstream)
		}
		if svc2.ProxyIdentity != svc.ProxyIdentity {
			t.Errorf("service %q: expected ProxyIdentity %q, got %q", name, svc.ProxyIdentity, svc2.ProxyIdentity)
		}
		if svc2.Root != svc.Root {
			t.Errorf("service %q: expected Root %q, got %q", name, svc.Root, svc2.Root)
		}
		if svc2.Binary != svc.Binary {
			t.Errorf("service %q: expected Binary %q, got %q", name, svc.Binary, svc2.Binary)
		}
		if len(svc2.Args) != len(svc.Args) {
			t.Errorf("service %q: expected %d args, got %d", name, len(svc.Args), len(svc2.Args))
		}
		if len(svc2.Env) != len(svc.Env) {
			t.Errorf("service %q: expected %d env vars, got %d", name, len(svc.Env), len(svc2.Env))
		}
		if svc2.Health.Port != svc.Health.Port {
			t.Errorf("service %q: expected Health.Port %d, got %d", name, svc.Health.Port, svc2.Health.Port)
		}
	}
}

// The pinned profile is the whole point of the agent env block: without it an
// agent resolves its profile from the login username at service-start time and
// only starts for an operator whose name matches a profiles/ directory.
func TestGenerateLaunchdPlistPinsProfile(t *testing.T) {
	r := &Registry{}
	plist, err := r.GenerateLaunchdPlist("demo", Service{Type: "proxy"}, "acme", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if err != nil {
		t.Fatalf("GenerateLaunchdPlist: %v", err)
	}
	if !strings.Contains(plist, "<key>HOME_STACK_PROFILE</key>\n\t\t<string>acme</string>") {
		t.Errorf("plist does not pin the profile:\n%s", plist)
	}
}

// A service's own env merges around the pin, stays sorted, and cannot clobber
// it (Validate rejects the key outright — see TestValidateRejectsReservedEnv).
func TestGenerateLaunchdPlistMergesServiceEnvSorted(t *testing.T) {
	r := &Registry{}
	svc := Service{Type: "proxy", Env: map[string]string{"LOG_LEVEL": "info", "APP_MODE": "production"}}
	plist, err := r.GenerateLaunchdPlist("demo", svc, "beta", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if err != nil {
		t.Fatalf("GenerateLaunchdPlist: %v", err)
	}
	iApp := strings.Index(plist, "APP_MODE")
	iProfile := strings.Index(plist, "HOME_STACK_PROFILE")
	iLog := strings.Index(plist, "LOG_LEVEL")
	if iApp < 0 || iProfile < 0 || iLog < 0 {
		t.Fatalf("expected all three keys present:\n%s", plist)
	}
	if !(iApp < iProfile && iProfile < iLog) {
		t.Errorf("env keys not sorted (APP_MODE=%d HOME_STACK_PROFILE=%d LOG_LEVEL=%d)", iApp, iProfile, iLog)
	}
}

// An empty pin is worse than no pin: common.sh treats HOME_STACK_PROFILE="" as
// unset and falls back to guessing, so the plist would look fixed while
// behaving exactly as it did before. Fail instead of emitting <string></string>.
func TestGeneratePlistRejectsEmptyProfile(t *testing.T) {
	r := &Registry{}
	if _, err := r.GenerateLaunchdPlist("demo", Service{Type: "proxy"}, "", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack"); err == nil {
		t.Error("agent plist: expected an error for an empty profile, got none")
	}
	if _, err := r.GenerateSystemDaemonPlist("caddy", Service{Type: "system"}, "", "/bundle", "/Users/test", "io.example"); err == nil {
		t.Error("daemon plist: expected an error for an empty profile, got none")
	}
}

func TestValidateRejectsReservedEnv(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"demo": {
			Type:      "proxy",
			Subdomain: "demo",
			Upstream:  "127.0.0.1:9000",
			Env:       map[string]string{"HOME_STACK_PROFILE": "someone-elses-profile"},
		},
	}}
	err := r.Validate("example.com")
	if err == nil {
		t.Fatal("expected Validate to reject a service setting HOME_STACK_PROFILE")
	}
	if !strings.Contains(err.Error(), "reserved") {
		t.Errorf("error should explain the key is reserved, got: %v", err)
	}
}

// --- auth: field -----------------------------------------------------------

func TestValidateRegistryRejectsInvalidAuth(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "yes-please"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected unknown auth value to be rejected")
	}

	// Caddy can only gate a route it serves. A loopback-only upstream would
	// keep answering unauthenticated callers, so claiming auth on it is a
	// misconfiguration rather than a harmless no-op.
	r = &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
		"headless": {Type: "proxy", Upstream: "127.0.0.1:31496", Auth: "tailnet"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected auth on a service with no subdomain or host to be rejected")
	}

	// sso has nowhere to forward without a broker registered.
	r = &Registry{Services: map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "sso"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected auth: sso without a tinyauth service to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth"},
		"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "tailnet-or-sso"},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected auth requiring a broker with no upstream to be rejected")
	}
}

func TestValidateRegistryAcceptsEveryAuthMode(t *testing.T) {
	for _, mode := range []string{"", "none", "tailnet", "sso", "tailnet-or-sso"} {
		r := &Registry{Services: map[string]Service{
			"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
			"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: mode},
		}}
		if err := r.Validate("home.example.com"); err != nil {
			t.Fatalf("auth %q should be valid, got: %v", mode, err)
		}
	}
}

// An entry that predates the auth field must generate exactly what it did
// before, so adopting this feature never silently rewrites existing routes.
func TestGenerateCaddyfileAbsentAuthIsUnchanged(t *testing.T) {
	base := map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510"},
	}
	withField := map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "none"},
	}
	a := (&Registry{Services: base}).GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	b := (&Registry{Services: withField}).GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	if a != b {
		t.Fatalf("auth: none must generate identically to an absent auth field\n--- absent ---\n%s\n--- none ---\n%s", a, b)
	}
	if strings.Contains(a, "tailscale_auth") || strings.Contains(a, "forward_auth") {
		t.Fatal("an ungated service must emit no auth directives")
	}
}

func TestGenerateCaddyfileAuthTailnet(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "tailnet"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	if !strings.Contains(out, "tailscale_auth") {
		t.Fatal("expected tailscale_auth directive")
	}
	if !strings.Contains(out, "header_up X-Webauth-User {http.auth.user.tailscale_login}") {
		t.Fatal("expected resolved identity to be passed upstream")
	}
	// The gate is worthless if it lands after the thing it protects.
	if strings.Index(out, "tailscale_auth") > strings.Index(out, "reverse_proxy 127.0.0.1:31510") {
		t.Fatal("tailscale_auth must precede the reverse_proxy it gates")
	}
}

func TestGenerateCaddyfileAuthSSO(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
		"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "sso"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	if !strings.Contains(out, "forward_auth 127.0.0.1:31600") {
		t.Fatal("expected forward_auth pointed at the registered broker upstream")
	}
	if strings.Contains(out, "tailscale_auth") {
		t.Fatal("auth: sso must not emit tailscale_auth")
	}
}

func TestGenerateCaddyfileAuthTailnetOrSSO(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
		"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "tailnet-or-sso"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	for _, want := range []string{
		"@svc_tailnet remote_ip 100.64.0.0/10",
		"handle @svc_tailnet {",
		"tailscale_auth",
		"forward_auth 127.0.0.1:31600",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected %q in chained output:\n%s", want, out)
		}
	}
	// Tailnet lane first: the fallback only applies to what it does not match.
	if strings.Index(out, "tailscale_auth") > strings.Index(out, "forward_auth") {
		t.Fatal("the tailnet lane must be emitted before the SSO fallback")
	}
}

// A split service exposes several handlers; the gate has to cover all of them,
// or an API prefix stays reachable without authentication.
func TestGenerateCaddyfileAuthWrapsEntireSplitService(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"svc": {Type: "split", Subdomain: "svc", Upstream: "127.0.0.1:31510", Root: "~/d", APIPath: "/api,/ws", Auth: "tailnet"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	gate := strings.Index(out, "tailscale_auth")
	for _, later := range []string{"handle /api*", "handle /ws*", "file_server"} {
		if idx := strings.Index(out, later); idx < gate {
			t.Fatalf("%q must fall under the auth gate", later)
		}
	}
}

// proxy_identity and auth both add header_up lines to the same block.
func TestGenerateCaddyfileAuthComposesWithProxyIdentity(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"svc": {Type: "proxy", Subdomain: "svc", Upstream: "100.64.0.8:31511", ProxyIdentity: "upstream", Auth: "tailnet"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	for _, want := range []string{
		"header_up Host {upstream_hostport}",
		"header_up Origin http://{upstream_hostport}",
		"header_up X-Webauth-User {http.auth.user.tailscale_login}",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected %q when proxy_identity and auth are combined:\n%s", want, out)
		}
	}
}

// The proxy secret is the capability to be believed by Admin, so it must go to
// Admin's upstream and nowhere else -- a gated backend holding it could
// impersonate any identity to the mutation API over loopback.
func TestProxySecretEmittedOnlyForAdmin(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
		"admin":    {Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510", Auth: "tailnet-or-sso"},
		"other":    {Type: "proxy", Subdomain: "other", Upstream: "127.0.0.1:31700", Auth: "tailnet-or-sso"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	adminBlock := out[strings.Index(out, "@admin host"):strings.Index(out, "@other host")]
	otherBlock := out[strings.Index(out, "@other host"):]
	if strings.Count(adminBlock, "X-Home-Stack-Proxy-Auth") != 2 {
		t.Fatalf("admin should receive the secret in both lanes:\n%s", adminBlock)
	}
	if strings.Contains(otherBlock, "X-Home-Stack-Proxy-Auth") {
		t.Fatalf("non-admin gated upstreams must not receive the secret:\n%s", otherBlock)
	}
}

// Each gated lane must strip the identity headers the OTHER lane would set, or
// a caller can smuggle its own through -- and Admin prefers X-Webauth-User, so
// a spoofed one would outrank the broker's verified Remote-User.
func TestGatedLanesStripForeignIdentityHeaders(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600"},
		"tn":       {Type: "proxy", Subdomain: "tn", Upstream: "127.0.0.1:31701", Auth: "tailnet"},
		"so":       {Type: "proxy", Subdomain: "so", Upstream: "127.0.0.1:31702", Auth: "sso"},
		"plain":    {Type: "proxy", Subdomain: "plain", Upstream: "127.0.0.1:31703"},
	}}
	out := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	tnBlock := out[strings.Index(out, "@tn host"):]
	tnBlock = tnBlock[:strings.Index(tnBlock, "@")+strings.Index(tnBlock[1:], "@")]
	if !strings.Contains(out[strings.Index(out, "@tn host"):], "header_up -Remote-User") {
		t.Fatal("tailnet lane must strip caller-supplied Remote-* headers")
	}
	soIdx := strings.Index(out, "@so host")
	if !strings.Contains(out[soIdx:], "header_up -X-Webauth-User") {
		t.Fatal("sso lane must strip caller-supplied X-Webauth-* headers")
	}
	plainIdx := strings.Index(out, "@plain host")
	plainEnd := strings.Index(out[plainIdx:], "}")
	if strings.Contains(out[plainIdx:plainIdx+plainEnd+40], "header_up -") {
		t.Fatal("ungated services must remain byte-identical: no header deletions")
	}
}

// Zero-click mutations must be attributed: the audit actor comes from the
// proxy-verified identity when Basic Auth is absent.
func TestAuditActorFromProxyIdentity(t *testing.T) {
	s := &server{adminUsername: "admin", adminPassword: "pw", proxyAuthSecret: "s3cret"}
	req := httptest.NewRequest("POST", "/api/actions", nil)
	req.Header.Set("X-Home-Stack-Proxy-Auth", "s3cret")
	req.Header.Set("X-Webauth-User", "example")
	if got := s.proxyIdentity(req); got != "example" {
		t.Fatalf("expected proxy identity to name the actor, got %q", got)
	}
}

// --- enabled: field ---------------------------------------------------------

func boolPtr(b bool) *bool { return &b }

func TestIsEnabledDefaultsTrueWhenAbsent(t *testing.T) {
	var svc Service
	if !svc.IsEnabled() {
		t.Fatal("a service with no enabled field must default to enabled")
	}
	svc.Enabled = boolPtr(false)
	if svc.IsEnabled() {
		t.Fatal("enabled: false must be respected")
	}
	svc.Enabled = boolPtr(true)
	if !svc.IsEnabled() {
		t.Fatal("enabled: true must be respected")
	}
}

func TestGeneratesAgentPlist(t *testing.T) {
	cases := []struct {
		name string
		svc  Service
		want bool
	}{
		{"enabled proxy", Service{Type: "proxy"}, true},
		{"disabled proxy", Service{Type: "proxy", Enabled: boolPtr(false)}, false},
		{"enabled system", Service{Type: "system"}, false},
		{"disabled system", Service{Type: "system", Enabled: boolPtr(false)}, false},
		{"enabled static", Service{Type: "static"}, false},
		{"disabled static", Service{Type: "static", Enabled: boolPtr(false)}, false},
		{"explicit enabled true", Service{Type: "proxy", Enabled: boolPtr(true)}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.svc.generatesAgentPlist(); got != tc.want {
				t.Fatalf("generatesAgentPlist() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestGenerateCaddyfileOmitsDisabledServiceRoute(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"disabled-svc": {Type: "proxy", Subdomain: "disabled-svc", Upstream: "127.0.0.1:31999", Enabled: boolPtr(false)},
		"enabled-svc":  {Type: "proxy", Subdomain: "enabled-svc", Upstream: "127.0.0.1:31998"},
	}}
	caddyfile := r.GenerateCaddyfile("a@example.com", "100.64.0.8", "/Users/test", "home.example.com")
	if strings.Contains(caddyfile, "disabled-svc") {
		t.Fatalf("disabled service must not get a Caddy route:\n%s", caddyfile)
	}
	if !strings.Contains(caddyfile, "host enabled-svc.home.example.com") {
		t.Fatalf("enabled sibling must still get a Caddy route:\n%s", caddyfile)
	}
}

func TestValidateStillValidatesDisabledService(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"bad": {Type: "proxy", Host: "bad.home.example.com\nrespond hacked", Upstream: "127.0.0.1:31510", Enabled: boolPtr(false)},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("a disabled service with an invalid host must still fail validation, so it can be safely re-enabled later")
	}
}

// TestEnabledFalseAcrossGenerationPaths exercises the full sync pipeline (the
// same code syncSystem, Diff, and Apply each drive) and checks that a
// disabled service produces no Caddy route, no agent plist, and no
// diff-reported plist change in any of them, while its enabled sibling is
// unaffected and the catalog still records the flag.
func TestEnabledFalseAcrossGenerationPaths(t *testing.T) {
	tmpDir := t.TempDir()
	profile := "enabled-test"
	profileDir := filepath.Join(tmpDir, "profiles", profile)
	bundleDir := filepath.Join(tmpDir, "portable", "home-stack")
	scriptsDir := filepath.Join(bundleDir, "scripts")
	if err := os.MkdirAll(profileDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(scriptsDir, 0755); err != nil {
		t.Fatal(err)
	}

	servicesYAML := `services:
  admin:
    type: proxy
    subdomain: admin
    upstream: 127.0.0.1:31510
  disabled-svc:
    type: proxy
    subdomain: disabled-svc
    upstream: 127.0.0.1:31999
    enabled: false
`
	if err := os.WriteFile(filepath.Join(profileDir, "services.yaml"), []byte(servicesYAML), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scriptsDir, "reload-caddy.sh"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}

	env := map[string]string{
		"HOME_STACK_PARENT_DOMAIN":     "enabled.test",
		"HOME_STACK_TAILNET_IP":        "127.0.0.1",
		"HOME_STACK_ACME_EMAIL":        "test@test",
		"HOME_STACK_OWNER_HOME":        tmpDir,
		"HOME_STACK_IDENTIFIER_PREFIX": "test.enabled",
		"HOME_STACK_ADMIN_USERNAME":    "admin",
		"HOME_STACK_PROFILE":           profile,
		"HOME_STACK_REPO_ROOT":         tmpDir,
	}
	for k, v := range env {
		t.Setenv(k, v)
	}

	s := &server{bundleDir: bundleDir}
	if _, err := s.syncSystem(); err != nil {
		t.Fatalf("syncSystem failed: %v", err)
	}

	caddyfile, err := os.ReadFile(filepath.Join(bundleDir, "Caddyfile"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(caddyfile), "disabled-svc") {
		t.Fatalf("sync: disabled service must not get a Caddy route:\n%s", caddyfile)
	}
	if !strings.Contains(string(caddyfile), "admin.enabled.test") {
		t.Fatalf("sync: enabled sibling must get a Caddy route:\n%s", caddyfile)
	}

	launchdDir := filepath.Join(bundleDir, "launchd")
	disabledPlist := filepath.Join(launchdDir, "test.enabled.home-stack.disabled-svc.plist")
	if _, err := os.Stat(disabledPlist); !os.IsNotExist(err) {
		t.Fatalf("sync: disabled service must not get a plist (stat err=%v)", err)
	}
	enabledPlist := filepath.Join(launchdDir, "test.enabled.home-stack.admin.plist")
	if _, err := os.Stat(enabledPlist); err != nil {
		t.Fatalf("sync: enabled sibling must get a plist: %v", err)
	}

	catalogData, err := os.ReadFile(filepath.Join(bundleDir, "catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	var catalog map[string]Service
	if err := json.Unmarshal(catalogData, &catalog); err != nil {
		t.Fatal(err)
	}
	disabledEntry, ok := catalog["disabled-svc"]
	if !ok {
		t.Fatal("catalog must still list the disabled service")
	}
	if disabledEntry.Enabled == nil || *disabledEntry.Enabled {
		t.Fatalf("catalog must carry enabled: false for disabled-svc, got %+v", disabledEntry.Enabled)
	}
	if catalog["admin"].Enabled != nil {
		t.Fatalf("catalog should omit enabled for a defaulted-enabled service, got %+v", catalog["admin"].Enabled)
	}

	diff, err := Diff(bundleDir, profile)
	if err != nil {
		t.Fatalf("Diff failed: %v", err)
	}
	for _, d := range diff.Launchd.Details {
		if strings.Contains(d, "disabled-svc") {
			t.Fatalf("Diff must not report any plist change for a disabled service: %v", diff.Launchd.Details)
		}
	}

	if _, err := Apply(bundleDir, profile); err != nil {
		t.Fatalf("Apply failed: %v", err)
	}
	if _, err := os.Stat(disabledPlist); !os.IsNotExist(err) {
		t.Fatalf("apply: disabled service must not get a plist (stat err=%v)", err)
	}
}

// --- Validate: enabled: false dependencies ----------------------------------

// The ingress cannot be "disabled": install-launchd.sh hard-requires the
// daemon plist to exist, so an enabled: false type: system entry is rejected
// outright rather than silently producing a stack with no Caddy daemon.
func TestValidateRejectsDisabledSystemService(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"caddy": {Type: "system", Subdomain: "*", Enabled: boolPtr(false)},
	}}
	err := r.Validate("home.example.com")
	if err == nil {
		t.Fatal("expected disabling a type: system service to be rejected")
	}
	if !strings.Contains(err.Error(), "cannot be disabled") {
		t.Errorf("error should say the ingress cannot be disabled, got: %v", err)
	}
}

// admin owns the Portal projection and the control plane; disabling it would
// silently strand both, so it is rejected the same way as the ingress.
func TestValidateRejectsDisabledAdminService(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"admin": {Type: "proxy", Subdomain: "admin", Upstream: "127.0.0.1:31510", Enabled: boolPtr(false)},
	}}
	err := r.Validate("home.example.com")
	if err == nil {
		t.Fatal("expected disabling the admin service to be rejected")
	}
	if !strings.Contains(err.Error(), "admin") {
		t.Errorf("error should name admin, got: %v", err)
	}
}

// GenerateCaddyfile still unconditionally emits forward_auth to the broker's
// upstream for every dependent that requires it, disabled broker or not —
// disabling the broker while a dependent is still enabled would make every
// one of those routes 502.
func TestValidateRejectsDisabledAuthBrokerWithEnabledDependent(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600", Enabled: boolPtr(false)},
		"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "sso"},
	}}
	err := r.Validate("home.example.com")
	if err == nil {
		t.Fatal("expected disabling the auth broker while a dependent needs it to be rejected")
	}
	if !strings.Contains(err.Error(), "svc") {
		t.Errorf("error should name the dependent service, got: %v", err)
	}
}

// A dependent that is itself disabled generates no route at all (see
// GenerateCaddyfile), so it never actually calls forward_auth against the
// disabled broker — disabling the broker in that case must be allowed.
func TestValidateAllowsDisabledAuthBrokerWithOnlyDisabledDependents(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600", Enabled: boolPtr(false)},
		"svc":      {Type: "proxy", Subdomain: "svc", Upstream: "127.0.0.1:31510", Auth: "sso", Enabled: boolPtr(false)},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("disabling the broker should be allowed when the only dependent is also disabled, got: %v", err)
	}
}

// With no dependent at all, disabling the broker is ordinary enabled: false
// behaviour and must be allowed.
func TestValidateAllowsDisabledAuthBrokerWithoutDependents(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"tinyauth": {Type: "proxy", Subdomain: "auth", Upstream: "127.0.0.1:31600", Enabled: boolPtr(false)},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("disabling the broker with no dependents should be allowed, got: %v", err)
	}
}

// --- RoutableHost / RoutableURL ----------------------------------------------

func TestRoutableHost(t *testing.T) {
	parent := "home.example.com"
	cases := []struct {
		name string
		svc  Service
		want string
	}{
		{"subdomain", Service{Subdomain: "admin"}, "admin.home.example.com"},
		{"wildcard subdomain", Service{Subdomain: "*"}, ""},
		{"wildcard sub-subdomain", Service{Subdomain: "*.dev"}, ""},
		{"external host", Service{Host: "external.other.com"}, "external.other.com"},
		{"no host or subdomain", Service{}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.svc.RoutableHost(parent); got != tc.want {
				t.Errorf("RoutableHost(%+v) = %q; want %q", tc.svc, got, tc.want)
			}
		})
	}
}

func TestRoutableURL(t *testing.T) {
	parent := "home.example.com"
	cases := []struct {
		name string
		svc  Service
		want string
	}{
		{"routable and enabled", Service{Subdomain: "admin"}, "https://admin.home.example.com"},
		{"routable but disabled", Service{Subdomain: "admin", Enabled: boolPtr(false)}, ""},
		{"wildcard", Service{Subdomain: "*"}, ""},
		{"no route", Service{}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.svc.RoutableURL(parent); got != tc.want {
				t.Errorf("RoutableURL(%+v) = %q; want %q", tc.svc, got, tc.want)
			}
		})
	}
}

// --- HOME_STACK_DATA_DIR honours HOME_STACK_CONFIG_DIR -----------------------

// engine.go used to hardcode HOME_STACK_DATA_DIR from ownerHome directly,
// ignoring a HOME_STACK_CONFIG_DIR override that GenerateSystemDaemonPlist
// (and common.sh) already honour for the daemon's own directories.
func TestGenerateLaunchdPlistDataDirHonoursConfigDirOverride(t *testing.T) {
	r := &Registry{}

	defaultPlist, err := r.GenerateLaunchdPlist("demo", Service{Type: "proxy"}, "acme", "/bundle", "/Users/test", "io.example", "home.example.com", "/Users/test/.config/home-stack")
	if err != nil {
		t.Fatalf("GenerateLaunchdPlist: %v", err)
	}
	if !strings.Contains(defaultPlist, "<string>/Users/test/.config/home-stack/data/demo</string>") {
		t.Fatalf("expected default HOME_STACK_DATA_DIR under ownerHome/.config/home-stack, got:\n%s", defaultPlist)
	}

	overridden, err := r.GenerateLaunchdPlist("demo", Service{Type: "proxy"}, "acme", "/bundle", "/Users/test", "io.example", "home.example.com", "/custom/config/dir")
	if err != nil {
		t.Fatalf("GenerateLaunchdPlist: %v", err)
	}
	if !strings.Contains(overridden, "<string>/custom/config/dir/data/demo</string>") {
		t.Fatalf("expected HOME_STACK_DATA_DIR to honour the overridden config dir, got:\n%s", overridden)
	}
	if strings.Contains(overridden, "/Users/test/.config/home-stack/data/demo") {
		t.Fatalf("overridden config dir must not fall back to the ownerHome default:\n%s", overridden)
	}
}

// --- install: field ----------------------------------------------------------

func TestValidateInstallAcceptsEveryMethod(t *testing.T) {
	for _, method := range []string{"github-release", "xcaddy", "source-go", "npm-global", "opencode", "hermes-pinned", "brew"} {
		t.Run(method, func(t *testing.T) {
			svc := Service{Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{
				Method: method,
				Source: "acme/widget",
			}}
			if method == "github-release" {
				svc.Install.Asset = "widget_darwin_{arch}"
				svc.Install.Binary = "bin/widget"
			}
			r := &Registry{Services: map[string]Service{"widget": svc}}
			if err := r.Validate("home.example.com"); err != nil {
				t.Fatalf("install.method %q should be valid, got: %v", method, err)
			}
		})
	}
}

func TestValidateInstallRejectsUnknownMethod(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "curl-and-pray", Source: "acme/widget"}},
	}}
	err := r.Validate("home.example.com")
	if err == nil {
		t.Fatal("expected unknown install.method to be rejected")
	}
	if !strings.Contains(err.Error(), "widget") {
		t.Errorf("error should name the service, got: %v", err)
	}
}

func TestValidateInstallRequiresSource(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "npm-global"}},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected missing install.source to be rejected")
	}
}

func TestValidateInstallGithubReleaseRequiresAssetAndBinary(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "github-release", Source: "acme/widget"}},
	}}
	err := r.Validate("home.example.com")
	if err == nil {
		t.Fatal("expected github-release without asset/binary to be rejected")
	}

	r = &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "github-release", Source: "acme/widget", Asset: "widget_{arch}"}},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected github-release without binary to be rejected")
	}
}

func TestValidateInstallOtherMethodsDoNotRequireAssetOrBinary(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "npm-global", Source: "widget-cli"}},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("npm-global should not require asset/binary, got: %v", err)
	}
}

func TestValidateInstallRejectsControlCharacters(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true", Install: &InstallSpec{Method: "npm-global", Source: "widget\ncli"}},
	}}
	if err := r.Validate("home.example.com"); err == nil {
		t.Fatal("expected control characters in install.source to be rejected")
	}
}

func TestValidateAllowsAbsentInstall(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"widget": {Type: "task", Binary: "/usr/bin/true"},
	}}
	if err := r.Validate("home.example.com"); err != nil {
		t.Fatalf("a service with no install: block should validate fine, got: %v", err)
	}
}

func TestInstallRoundTripsThroughCatalog(t *testing.T) {
	r := &Registry{Services: map[string]Service{
		"pocket-id": {
			Type: "proxy", Subdomain: "id", Upstream: "127.0.0.1:31520",
			Install: &InstallSpec{
				Method:     "github-release",
				Source:     "pocket-id/pocket-id",
				Pin:        "v1.9.0",
				VersionCmd: "pocket-id --version",
				Asset:      "pocket-id_darwin_{arch}",
				Binary:     "bin/pocket-id",
			},
		},
	}}
	catalog := buildCatalog(r, "home.example.com")
	entry, ok := catalog["pocket-id"]
	if !ok || entry.Install == nil {
		t.Fatal("expected catalog to carry the install: block")
	}
	if entry.Install.Method != "github-release" || entry.Install.Pin != "v1.9.0" {
		t.Fatalf("catalog install block does not match source: %+v", entry.Install)
	}

	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{`"method":"github-release"`, `"source":"pocket-id/pocket-id"`, `"pin":"v1.9.0"`, `"version_cmd":"pocket-id --version"`} {
		if !strings.Contains(string(data), want) {
			t.Errorf("catalog JSON missing %q: %s", want, data)
		}
	}
}

// desiredArtifacts resolves configDir itself via envOr("HOME_STACK_CONFIG_DIR", ...),
// the same fallback GenerateSystemDaemonPlist already uses, so an override
// set in the environment reaches the agent plist too.
func TestDesiredArtifactsHonoursConfigDirEnvOverride(t *testing.T) {
	tmpDir := t.TempDir()
	r := &Registry{Services: map[string]Service{
		"worker": {Type: "proxy", Subdomain: "worker", Upstream: "127.0.0.1:31700"},
	}}
	t.Setenv("HOME_STACK_CONFIG_DIR", filepath.Join(tmpDir, "custom-config"))

	artifacts, err := r.desiredArtifacts("acme", "/bundle", tmpDir, "io.example", "home.example.com", "a@example.com", "100.64.0.8")
	if err != nil {
		t.Fatalf("desiredArtifacts: %v", err)
	}
	plist, ok := artifacts.agentPlists["worker"]
	if !ok {
		t.Fatal("expected an agent plist for worker")
	}
	wantDataDir := filepath.Join(tmpDir, "custom-config", "data", "worker")
	if !strings.Contains(plist, wantDataDir) {
		t.Fatalf("expected plist to use HOME_STACK_CONFIG_DIR override for the data dir, got:\n%s", plist)
	}
}
