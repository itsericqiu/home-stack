package main

func buildDeployPreview(r *Registry) deployPreviewResponse {
	valid := true
	details := "registry validates"
	parentDomain, err := requiredParentDomain()
	if err != nil {
		return deployPreviewResponse{OK: false, Valid: false, Details: err.Error()}
	}
	if err := r.Validate(parentDomain); err != nil {
		valid = false
		details = err.Error()
	}
	return deployPreviewResponse{
		OK:             valid,
		Valid:          valid,
		ChangedFiles:   []string{"portable/home-stack/Caddyfile", "portable/home-stack/catalog.json", "portable/home-stack/launchd/*.plist"},
		PlannedActions: []string{"validate caddyfile", "write generated files"},
		Details:        details,
	}
}
