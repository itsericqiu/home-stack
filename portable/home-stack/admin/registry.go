package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// DeployDiff represents the structured diff between deployed state and desired state.
type DeployDiff struct {
	Caddyfile  DiffSection `json:"caddyfile"`
	Launchd    DiffSection `json:"launchd"`
	Catalog    DiffSection `json:"catalog"`
	HasChanges bool        `json:"has_changes"`
}

// DiffSection represents the changes for a specific component.
type DiffSection struct {
	Added   int      `json:"added"`
	Removed int      `json:"removed"`
	Changed int      `json:"changed"`
	Lines   []string `json:"lines,omitempty"`
	Details []string `json:"details,omitempty"`
}

// profilesDir resolves the directory containing per-profile subdirectories.
// HOME_STACK_PROFILES_DIR overrides the default (bundleDir/../../profiles) so
// staged tests and CI can point at a fixture tree without a symlink.
//
// The symlink at profiles/<name> remains the documented runtime mechanism for
// a real deployment: it needs no environment and works for launchd-launched
// processes. Engine-generated plists therefore pin only HOME_STACK_PROFILE
// into their EnvironmentVariables, never HOME_STACK_PROFILES_DIR -- the
// override exists for tests/CI, not for what gets deployed.
func profilesDir(bundleDir string) string {
	return envOr("HOME_STACK_PROFILES_DIR", filepath.Join(bundleDir, "../../profiles"))
}

// registryPath composes the services.yaml path for a profile under
// profilesDir(bundleDir). Both -d checks in the shell tooling and os.Stat
// here follow symlinks, so a symlinked profiles/<name> resolves the same way.
func registryPath(bundleDir, profile string) string {
	return filepath.Join(profilesDir(bundleDir), profile, "services.yaml")
}

// AddService adds or updates a service in the profile's services.yaml.
// Uses atomic write — validates before overwriting.
func AddService(bundleDir, profile, name string, svc Service) error {
	registryPath := registryPath(bundleDir, profile)

	// Load existing registry
	r, err := loadRegistry(registryPath)
	if err != nil {
		// If file doesn't exist, create a new registry
		if os.IsNotExist(err) {
			r = &Registry{Services: make(map[string]Service)}
		} else {
			return fmt.Errorf("failed to load registry: %w", err)
		}
	}

	if r.Services == nil {
		r.Services = make(map[string]Service)
	}

	r.Services[name] = svc

	// Validate the updated registry
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return err
	}
	if err := r.Validate(parentDomain); err != nil {
		return fmt.Errorf("validation failed: %w", err)
	}

	// Atomic write: marshal to tmp, validate by reloading, then rename
	data, err := yaml.Marshal(r)
	if err != nil {
		return fmt.Errorf("failed to marshal registry: %w", err)
	}

	tmpPath := registryPath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write temp file: %w", err)
	}

	// Validate the temp file by loading it
	if _, err := loadRegistry(tmpPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("validation of written registry failed: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpPath, registryPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	return nil
}

// RemoveService removes a service from the profile's services.yaml.
// Uses atomic write. Returns nil if the service doesn't exist.
func RemoveService(bundleDir, profile, name string) error {
	registryPath := registryPath(bundleDir, profile)

	// Load existing registry
	r, err := loadRegistry(registryPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // Nothing to remove
		}
		return fmt.Errorf("failed to load registry: %w", err)
	}

	if r.Services == nil {
		return nil // Nothing to remove
	}

	if _, exists := r.Services[name]; !exists {
		return nil // Nothing to remove
	}

	delete(r.Services, name)

	// If no services left, write empty services map
	if len(r.Services) == 0 {
		r.Services = make(map[string]Service)
	}

	// Atomic write
	data, err := yaml.Marshal(r)
	if err != nil {
		return fmt.Errorf("failed to marshal registry: %w", err)
	}

	tmpPath := registryPath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return fmt.Errorf("failed to write temp file: %w", err)
	}

	// Validate the temp file by loading it
	if _, err := loadRegistry(tmpPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("validation of written registry failed: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpPath, registryPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	return nil
}

// Diff compares deployed state (Caddyfile, plists, and catalog on disk)
// against desired state (services.yaml registry), via the same
// desiredArtifacts pipeline syncSystem and Apply write from — so the preview
// always matches what an apply would actually produce, including the daemon
// plist and its own stale-file pruning namespace, which earlier hand-rolled
// copies of this loop had each forgotten in a different way.
func Diff(bundleDir, profile string) (*DeployDiff, error) {
	diff := &DeployDiff{}

	// Resolve registry path
	regPath := registryPath(bundleDir, profile)
	if profile == "" {
		profile = os.Getenv("USER")
		regPath = registryPath(bundleDir, profile)
	}

	// Load registry
	r, err := loadRegistry(regPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load registry: %w", err)
	}

	// Get environment variables needed for generation
	email := os.Getenv("HOME_STACK_ACME_EMAIL")
	tailnetIP := os.Getenv("HOME_STACK_TAILNET_IP")
	ownerHome := os.Getenv("HOME_STACK_OWNER_HOME")
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return nil, err
	}
	// Previously read again inside the plist loop below with no empty/format
	// check — Apply and syncSystem both validate this before generating
	// anything; an empty or malformed prefix here used to silently compose
	// plist paths like ".home-stack.<name>.plist" that could never match
	// anything on disk, so the preview never converged.
	idPrefix := os.Getenv("HOME_STACK_IDENTIFIER_PREFIX")

	desired, err := r.desiredArtifacts(profile, bundleDir, ownerHome, idPrefix, parentDomain, email, tailnetIP)
	if err != nil {
		return nil, err
	}

	// Compare Caddyfile
	caddyfilePath := filepath.Join(bundleDir, "Caddyfile")
	diff.Caddyfile = diffFiles(caddyfilePath, desired.caddyfile)
	diff.HasChanges = diff.HasChanges || diff.Caddyfile.HasChanges()

	// Compare Launchd plists — agents and daemons, with the same
	// content-aware, idPrefix-scoped comparison.
	launchdDir := filepath.Join(bundleDir, "launchd")
	daemonDir := filepath.Join(launchdDir, "daemons")
	diff.Launchd = mergeDiffSections(
		diffPlists(launchdDir, idPrefix, desired.agentPlists),
		diffPlists(daemonDir, idPrefix, desired.daemonPlists),
	)
	diff.HasChanges = diff.HasChanges || diff.Launchd.HasChanges()

	// Compare Catalog
	catalogPath := filepath.Join(bundleDir, "catalog.json")
	diff.Catalog = diffCatalog(catalogPath, buildCatalog(r, parentDomain))
	diff.HasChanges = diff.HasChanges || diff.Catalog.HasChanges()

	return diff, nil
}

// HasChanges returns true if the diff section has any changes.
func (d DiffSection) HasChanges() bool {
	return d.Added > 0 || d.Removed > 0 || d.Changed > 0
}

// diffFiles compares a file on disk with desired content.
func diffFiles(filePath string, desiredContent string) DiffSection {
	section := DiffSection{}

	// Read existing file
	existing, err := os.ReadFile(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			// File doesn't exist - everything is added
			lines := strings.Split(desiredContent, "\n")
			section.Added = len(lines)
			section.Lines = prependPrefix(lines, "+")
			section.Details = []string{fmt.Sprintf("File %s would be created", filepath.Base(filePath))}
			return section
		}
		section.Details = []string{fmt.Sprintf("Error reading %s: %v", filePath, err)}
		return section
	}

	existingStr := string(existing)
	if existingStr == desiredContent {
		section.Details = []string{"No changes"}
		return section
	}

	// Simple line-by-line diff
	existingLines := strings.Split(existingStr, "\n")
	desiredLines := strings.Split(desiredContent, "\n")

	section.Lines = computeLineDiff(existingLines, desiredLines)

	// Count changes (simplified)
	for _, line := range section.Lines {
		if strings.HasPrefix(line, "+") {
			section.Added++
		} else if strings.HasPrefix(line, "-") {
			section.Removed++
		}
	}

	section.Details = []string{
		fmt.Sprintf("%d additions, %d removals", section.Added, section.Removed),
	}

	return section
}

// diffPlists compares existing plist files with desired plist content.

// diffCatalog compares existing catalog.json against desired catalog at service level.
func diffCatalog(catalogPath string, desiredCatalog map[string]Service) DiffSection {
	section := DiffSection{}
	existing, err := os.ReadFile(catalogPath)
	if err != nil {
		if os.IsNotExist(err) {
			section.Added = len(desiredCatalog)
			for name := range desiredCatalog {
				section.Details = append(section.Details, fmt.Sprintf("Would add %s to catalog", name))
			}
			return section
		}
		section.Details = []string{fmt.Sprintf("Error reading catalog: %v", err)}
		return section
	}
	var existingCatalog map[string]Service
	if err := json.Unmarshal(existing, &existingCatalog); err != nil {
		section.Details = []string{"Catalog exists but is not valid JSON — would regenerate"}
		section.Changed = len(desiredCatalog)
		return section
	}
	for name := range desiredCatalog {
		if _, ok := existingCatalog[name]; !ok {
			section.Added++
			section.Details = append(section.Details, fmt.Sprintf("Would add %s to catalog", name))
		}
	}
	for name := range existingCatalog {
		if _, ok := desiredCatalog[name]; !ok {
			section.Removed++
			section.Details = append(section.Details, fmt.Sprintf("Would remove %s from catalog", name))
		}
	}
	return section
}

// agentPlistFilename is the one definition of what a service's plist is
// named under a given identifier prefix. The writer (writeArtifacts), the
// pruner (pruneStalePlists), and the differ (diffPlists) all call this
// instead of hand-composing "<idPrefix>.home-stack.<name>.plist" themselves,
// so the three can never quietly disagree about a filename again.
func agentPlistFilename(idPrefix, name string) string {
	return fmt.Sprintf("%s.home-stack.%s.plist", idPrefix, name)
}

// plistServiceName is agentPlistFilename's inverse: given a plist filename
// and the identifier prefix that owns this profile, it returns the service
// name, or ("", false) if the file is not one of this prefix's plists at
// all. Scoping on the full idPrefix (not just the ".home-stack." substring
// every prefix shares) matters: a leftover file from a different identifier
// — e.g. "other-prefix.home-stack.gone.plist" — must never be read as if it
// were this profile's "gone" service, which is exactly what a bare
// ".home-stack." search would do, and which made a stray file collide with
// an unrelated same-named service and kept `hs deploy --preview` from ever
// converging.
func plistServiceName(idPrefix, filename string) (string, bool) {
	prefix := idPrefix + ".home-stack."
	if !strings.HasPrefix(filename, prefix) || !strings.HasSuffix(filename, ".plist") {
		return "", false
	}
	return strings.TrimSuffix(strings.TrimPrefix(filename, prefix), ".plist"), true
}

// diffPlists compares the plists that exist under launchdDir's <idPrefix>
// namespace against desiredPlists (service name -> content), content-aware:
// a same-named plist whose bytes differ from the file on disk counts as
// Changed, not silently ignored, and a file belonging to a different
// identifier prefix is invisible to it (see plistServiceName) rather than
// colliding with a same-named desired service.
func diffPlists(launchdDir, idPrefix string, desiredPlists map[string]string) DiffSection {
	section := DiffSection{}

	existingPathByName := make(map[string]string)
	if entries, err := os.ReadDir(launchdDir); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			if name, ok := plistServiceName(idPrefix, entry.Name()); ok {
				existingPathByName[name] = filepath.Join(launchdDir, entry.Name())
			}
		}
	}

	for name, desiredContent := range desiredPlists {
		existingPath, exists := existingPathByName[name]
		if !exists {
			section.Added++
			section.Details = append(section.Details, fmt.Sprintf("Would create plist for %s", name))
			continue
		}
		existingContent, err := os.ReadFile(existingPath)
		if err != nil || string(existingContent) != desiredContent {
			section.Changed++
			section.Details = append(section.Details, fmt.Sprintf("Would update plist for %s", name))
		}
	}
	for name := range existingPathByName {
		if _, ok := desiredPlists[name]; !ok {
			section.Removed++
			section.Details = append(section.Details, fmt.Sprintf("Would remove plist for %s", name))
		}
	}

	return section
}

// mergeDiffSections combines two DiffSection tallies (e.g. agent plists and
// daemon plists, which live in different directories and are diffed
// separately) into the one section a caller reports as "Launchd".
func mergeDiffSections(sections ...DiffSection) DiffSection {
	var merged DiffSection
	for _, s := range sections {
		merged.Added += s.Added
		merged.Removed += s.Removed
		merged.Changed += s.Changed
		merged.Lines = append(merged.Lines, s.Lines...)
		merged.Details = append(merged.Details, s.Details...)
	}
	return merged
}

// pruneStalePlists removes plists in dir that are not in the desired set —
// a service removed from the registry, or now disabled. install-launchd.sh's
// own prune step keys off what already exists in each directory, so a stale
// file left behind can never be noticed there. Only files in dir's own
// "<idPrefix>.home-stack.*.plist" namespace are touched (see
// plistServiceName): writeArtifacts calls this once for the agents directory
// and once for launchd/daemons/, each with that directory's own desired set,
// so this never has to know which kind of dir it was given, and one call's
// pruning can never reach across into the other's namespace since
// os.ReadDir is not recursive and directories are skipped explicitly below.
func pruneStalePlists(dir, idPrefix string, desired map[string]bool) []string {
	var logs []string
	entries, err := os.ReadDir(dir)
	if err != nil {
		return logs
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		svcName, ok := plistServiceName(idPrefix, entry.Name())
		if !ok || desired[svcName] {
			continue
		}
		if err := os.Remove(filepath.Join(dir, entry.Name())); err != nil {
			continue
		}
		logs = append(logs, fmt.Sprintf("Removed stale plist for %s", svcName))
	}
	return logs
}

// computeLineDiff produces a simple unified diff-like output.
func computeLineDiff(oldLines, newLines []string) []string {
	// Simple diff: just show old and new (this is a simplified version)
	var result []string
	maxLen := len(oldLines)
	if len(newLines) > maxLen {
		maxLen = len(newLines)
	}

	hasDiff := false
	for i := 0; i < maxLen; i++ {
		var oldLine, newLine string
		if i < len(oldLines) {
			oldLine = oldLines[i]
		}
		if i < len(newLines) {
			newLine = newLines[i]
		}

		if oldLine != newLine {
			hasDiff = true
			if oldLine != "" {
				result = append(result, "-"+oldLine)
			}
			if newLine != "" {
				result = append(result, "+"+newLine)
			}
		}
	}

	if !hasDiff {
		result = append(result, " (no changes)")
	}

	return result
}

// prependPrefix adds a prefix to each line.
func prependPrefix(lines []string, prefix string) []string {
	result := make([]string, len(lines))
	for i, line := range lines {
		result[i] = prefix + line
	}
	return result
}

// hashString returns a SHA256 hash of the input string for comparison.
func hashString(s string) string {
	h := sha256.New()
	h.Write([]byte(s))
	return fmt.Sprintf("%x", h.Sum(nil))
}

// Apply regenerates all artifacts from the registry and returns the sync result.
// Does NOT reload Caddy — that's handled separately by the deploy.apply action.
func Apply(bundleDir, profile string) (string, error) {
	// The profile is threaded through to the generators rather than published
	// to the process environment: this runs inside an HTTP handler, and a
	// global Setenv would race concurrent requests while steering what gets
	// written into every plist.

	// We need to generate artifacts but NOT reload Caddy — same
	// desiredArtifacts/writeArtifacts pipeline syncSystem uses, stopping
	// short of the reload step (that's handled by the deploy.apply action).

	regPath := registryPath(bundleDir, profile)
	if _, statErr := os.Stat(regPath); statErr != nil {
		return "", fmt.Errorf("profile registry not found at %s; set HOME_STACK_PROFILE or USER to a valid profile name, or HOME_STACK_PROFILES_DIR to override the profiles directory", regPath)
	}
	r, err := loadRegistry(regPath)
	if err != nil {
		return "", fmt.Errorf("failed to load registry: %w", err)
	}

	email := os.Getenv("HOME_STACK_ACME_EMAIL")
	if email == "" {
		return "", fmt.Errorf("HOME_STACK_ACME_EMAIL is not set")
	}
	tailnetIP := os.Getenv("HOME_STACK_TAILNET_IP")
	ownerHome := os.Getenv("HOME_STACK_OWNER_HOME")
	if ownerHome == "" {
		return "", fmt.Errorf("HOME_STACK_OWNER_HOME is not set")
	}
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return "", err
	}
	idPrefix := os.Getenv("HOME_STACK_IDENTIFIER_PREFIX")
	if idPrefix == "" {
		return "", fmt.Errorf("HOME_STACK_IDENTIFIER_PREFIX is not set")
	}
	if err := validateIdentifierPrefix(idPrefix); err != nil {
		return "", err
	}

	artifacts, err := r.desiredArtifacts(profile, bundleDir, ownerHome, idPrefix, parentDomain, email, tailnetIP)
	if err != nil {
		return "", err
	}
	logs, err := writeArtifacts(bundleDir, idPrefix, artifacts)
	if err != nil {
		return "", err
	}

	// Note: Caddy reload is intentionally skipped here - that's handled by deploy.apply action

	return strings.Join(logs, "\n"), nil
}
