package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func proxyTestServer() *server {
	return &server{adminUsername: "admin", adminPassword: "pw", proxyAuthSecret: "s3cret"}
}

func doAuth(t *testing.T, s *server, mutate func(*http.Request)) int {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/services", nil)
	if mutate != nil {
		mutate(req)
	}
	rec := httptest.NewRecorder()
	s.withAuth(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(rec, req)
	return rec.Code
}

// The whole point of the shared secret: identity headers alone are attacker
// input on a loopback listener.
func TestProxyIdentityRejectsSpoofedHeadersWithoutSecret(t *testing.T) {
	s := proxyTestServer()
	if code := doAuth(t, s, func(r *http.Request) {
		r.Header.Set("X-Webauth-User", "example")
	}); code != http.StatusUnauthorized {
		t.Fatalf("identity header without the proxy secret must not authenticate, got %d", code)
	}
	if code := doAuth(t, s, func(r *http.Request) {
		r.Header.Set("Remote-User", "example")
		r.Header.Set("X-Home-Stack-Proxy-Auth", "wrong")
	}); code != http.StatusUnauthorized {
		t.Fatalf("a wrong proxy secret must not authenticate, got %d", code)
	}
}

// A valid secret with no user names nobody, so it must not authenticate.
func TestProxyIdentityRejectsSecretWithoutUser(t *testing.T) {
	s := proxyTestServer()
	if code := doAuth(t, s, func(r *http.Request) {
		r.Header.Set("X-Home-Stack-Proxy-Auth", "s3cret")
	}); code != http.StatusUnauthorized {
		t.Fatalf("secret without an identity must not authenticate, got %d", code)
	}
}

func TestProxyIdentityAcceptsBothLanes(t *testing.T) {
	s := proxyTestServer()
	for header, lane := range map[string]string{"X-Webauth-User": "tailnet", "Remote-User": "sso"} {
		code := doAuth(t, s, func(r *http.Request) {
			r.Header.Set("X-Home-Stack-Proxy-Auth", "s3cret")
			r.Header.Set(header, "example")
		})
		if code != http.StatusOK {
			t.Fatalf("%s lane (%s) should authenticate, got %d", lane, header, code)
		}
	}
}

// Break-glass must survive: Admin is the tool used to repair a broken
// identity layer.
func TestBasicAuthStillWorksAsBreakGlass(t *testing.T) {
	s := proxyTestServer()
	if code := doAuth(t, s, func(r *http.Request) { r.SetBasicAuth("admin", "pw") }); code != http.StatusOK {
		t.Fatalf("basic auth must still work, got %d", code)
	}
	if code := doAuth(t, s, func(r *http.Request) { r.SetBasicAuth("admin", "nope") }); code != http.StatusUnauthorized {
		t.Fatalf("wrong password must be rejected, got %d", code)
	}
}

// With no secret configured the proxy path is disabled entirely, so an
// unconfigured deployment cannot be bypassed by headers alone.
func TestProxyPathDisabledWhenSecretUnset(t *testing.T) {
	s := &server{adminUsername: "admin", adminPassword: "pw"}
	if code := doAuth(t, s, func(r *http.Request) {
		r.Header.Set("X-Home-Stack-Proxy-Auth", "")
		r.Header.Set("X-Webauth-User", "example")
	}); code != http.StatusUnauthorized {
		t.Fatalf("proxy path must be inert without a configured secret, got %d", code)
	}
}
