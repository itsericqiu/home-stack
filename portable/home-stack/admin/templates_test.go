package main

import (
	"strings"
	"testing"
)

// webappSource returns every embedded webapp asset concatenated. Behavior
// assertions run against the whole app, not one file, so splitting markup,
// styles, and scripts apart does not silently drop a check.
func webappSource(t *testing.T) string {
	t.Helper()
	var sb strings.Builder
	for _, name := range []string{"templates/index.html", "templates/app.css", "templates/app.js"} {
		body, err := templatesFS.ReadFile(name)
		if err != nil {
			t.Fatalf("reading %s: %v", name, err)
		}
		sb.Write(body)
		sb.WriteString("\n")
	}
	return sb.String()
}

func adminMarkup(t *testing.T) string {
	t.Helper()
	body, err := templatesFS.ReadFile("templates/index.html")
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestAdminTemplateIncludesResponsiveControlPlaneShell(t *testing.T) {
	app := webappSource(t)
	for _, want := range []string{"data-tab=\"triage\"", "data-tab=\"services\"", "data-tab=\"deploy\"", "data-tab=\"events\"", "data-tab=\"doctor\"", "status-bar", "Admin restarting"} {
		if !strings.Contains(app, want) {
			t.Fatalf("webapp missing %q", want)
		}
	}
	// Zoom control is a markup concern: assert on the document itself.
	html := adminMarkup(t)
	if strings.Contains(html, "user-scalable=no") || strings.Contains(html, "maximum-scale=1") {
		t.Fatal("template must not disable zoom")
	}
}

func TestAdminTemplateIncludesPendingAndReconnectBehavior(t *testing.T) {
	app := webappSource(t)
	for _, want := range []string{"waitForReconnect", "Admin restarting", "offline", "connected", "pending"} {
		if !strings.Contains(app, want) {
			t.Fatalf("webapp missing reconnect behavior %q", want)
		}
	}
}

func TestAdminTemplateIncludesClosableContainedServiceSheet(t *testing.T) {
	app := webappSource(t)
	for _, want := range []string{"id=\"sheet-backdrop\"", "closeSheet", "sheet-body", "sheet-open", "aria-label=\"Close service details\""} {
		if !strings.Contains(app, want) {
			t.Fatalf("webapp missing service sheet behavior %q", want)
		}
	}
	if strings.Contains(app, "JSON.stringify(s,null,2)") {
		t.Fatal("service sheet should render curated fields instead of a raw JSON scroller")
	}
}

// A missing signal must read as neutral only for a disabled service; for an
// enabled one (e.g. a plist that was synced but never installed) it must
// stay red, or that real problem would look identical to "disabled" on the
// Services tab. sig() takes an explicit disabled flag rather than treating
// every falsy signal as neutral -- see the app.js commit history for the
// version that regressed this.
func TestServiceSignalStaysRedForEnabledServiceMissingSignal(t *testing.T) {
	app := webappSource(t)
	if !strings.Contains(app, "function sig(x, label, tip, disabled)") {
		t.Fatal("sig() must take an explicit disabled flag")
	}
	if !strings.Contains(app, `const cls = disabled ? "" : x ? (x.ok || x.state === "running" ? "ok" : "err") : "err";`) {
		t.Fatal("sig() must render neutral only when disabled, and err (not neutral) for any other missing signal")
	}
	if !strings.Contains(app, `s.overall_state === "disabled"`) {
		t.Fatal("renderService must compute the disabled flag from overall_state before calling sig()")
	}
}

// TestAdminMarkupDelegatesToAssets pins the split itself: the document must
// reference the external assets and must not carry inline style/script bodies
// again (the single-blob shape that caused past hand-edit regressions).
func TestAdminMarkupDelegatesToAssets(t *testing.T) {
	html := adminMarkup(t)
	for _, want := range []string{`href="/assets/app.css"`, `src="/assets/app.js"`, "{{.ParentDomain}}"} {
		if !strings.Contains(html, want) {
			t.Fatalf("markup missing %q", want)
		}
	}
	if strings.Contains(html, "<style>") {
		t.Fatal("styles belong in templates/app.css, not inline")
	}
	if strings.Count(html, "<script") != 2 {
		t.Fatalf("expected exactly two script tags (template constants + app.js), got %d", strings.Count(html, "<script"))
	}
}
