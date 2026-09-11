package main

import (
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Registry struct {
	Services map[string]Service `yaml:"services"`
}

type Service struct {
	Upstream string `yaml:"upstream"`
	Host     string `yaml:"host"`
	// Enabled mirrors the admin engine's Service.Enabled: a pointer so
	// absence (every entry that predates the field) reads as enabled. A
	// disabled service gets no Caddy route from the engine, so this gateway
	// must not proxy to it either -- its upstream may not even be running.
	Enabled *bool `yaml:"enabled"`
}

// IsEnabled mirrors the admin engine's Service.IsEnabled: nil means enabled.
func (svc Service) IsEnabled() bool {
	return svc.Enabled == nil || *svc.Enabled
}

func main() {
	bundleDir := os.Getenv("HOME_STACK_BUNDLE_DIR")
	profile := os.Getenv("HOME_STACK_PROFILE")
	if profile == "" { profile = os.Getenv("USER") }
	
	registryPath := filepath.Join(bundleDir, "../../profiles", profile, "services.yaml")

	proxy := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			host := req.Host
			// Handle *.dev.<parent domain> wildcard hosts (matched via svc.Host below)
			
			// Load registry on every request for v1 (simple dynamic updates)
			data, err := os.ReadFile(registryPath)
			if err != nil {
				log.Printf("Error reading registry: %v", err)
				return
			}
			var r Registry
			yaml.Unmarshal(data, &r)

			for name, svc := range r.Services {
				if svc.Host == "" || !svc.IsEnabled() {
					continue
				}

				// Match explicit host or wildcard
				match := false
				if svc.Host == host {
					match = true
				} else if strings.HasPrefix(svc.Host, "*.") {
					pattern := strings.TrimPrefix(svc.Host, "*")
					if strings.HasSuffix(host, pattern) {
						match = true
					}
				}

				if match && name != "dev-gateway" {
					target, _ := url.Parse(fmt.Sprintf("http://%s", svc.Upstream))
					req.URL.Scheme = target.Scheme
					req.URL.Host = target.Host
					// Preserve path
					log.Printf("Proxying %s -> %s (via %s)", host, target.String(), name)
					return
				}
			}
			log.Printf("No route found for host: %s", host)
		},
	}

	addr := "127.0.0.1:31500"
	log.Printf("Dev Gateway starting on %s", addr)
	if err := http.ListenAndServe(addr, proxy); err != nil {
		log.Fatal(err)
	}
}
