package main

import "time"

type apiError struct {
	OK          bool     `json:"ok"`
	Message     string   `json:"message"`
	Cause       string   `json:"cause,omitempty"`
	Details     string   `json:"details,omitempty"`
	NextActions []string `json:"next_actions,omitempty"`
	EventID     string   `json:"event_id,omitempty"`
}

type overviewResponse struct {
	OK            bool             `json:"ok"`
	OverallState  string           `json:"overall_state"`
	GeneratedAt   time.Time        `json:"generated_at"`
	ServiceCounts map[string]int   `json:"service_counts"`
	TopIncidents  []incident       `json:"top_incidents"`
	RecentEvents  []adminEvent     `json:"recent_events"`
	Connection    connectionStatus `json:"connection"`
}

type connectionStatus struct {
	Backend string `json:"backend"`
	Caddy   string `json:"caddy"`
}

type sanitizedService struct {
	DisplayName   string       `json:"display_name"`
	Kind          string       `json:"kind"`
	Type          string       `json:"type"`
	Host          string       `json:"host,omitempty"`
	Upstream      string       `json:"upstream,omitempty"`
	ProxyIdentity string       `json:"proxy_identity,omitempty"`
	Root          string       `json:"root,omitempty"`
	APIPath       string       `json:"api_path,omitempty"`
	Lifecycle     string       `json:"lifecycle,omitempty"`
	Plist         string       `json:"plist,omitempty"`
	WorkingDir    string       `json:"working_dir,omitempty"`
	Binary        string       `json:"binary,omitempty"`
	Health        HealthConfig `json:"health"`
}

type incident struct {
	ID                 string   `json:"id"`
	Severity           string   `json:"severity"`
	Service            string   `json:"service,omitempty"`
	Title              string   `json:"title"`
	Explanation        string   `json:"explanation"`
	Confidence         string   `json:"confidence"`
	RecommendedActions []string `json:"recommended_actions,omitempty"`
}

type actionDescriptor struct {
	ID                   string   `json:"id"`
	Target               string   `json:"target,omitempty"`
	Label                string   `json:"label"`
	Risk                 string   `json:"risk"`
	RequiresConfirmation bool     `json:"requires_confirmation"`
	ExpectedEffect       string   `json:"expected_effect"`
	RollbackHint         string   `json:"rollback_hint,omitempty"`
	AllowedTargets       []string `json:"allowed_targets,omitempty"`
}

type actionRequest struct {
	Action  string  `json:"action"`
	Target  string  `json:"target"`
	Confirm bool    `json:"confirm"`
	Service Service `json:"service,omitempty"`
}

type actionResult struct {
	OK          bool     `json:"ok"`
	Message     string   `json:"message"`
	Cause       string   `json:"cause,omitempty"`
	Details     string   `json:"details,omitempty"`
	NextActions []string `json:"next_actions,omitempty"`
	EventID     string   `json:"event_id,omitempty"`
}

type adminEvent struct {
	ID       string    `json:"id"`
	Time     time.Time `json:"time"`
	Actor    string    `json:"actor"`
	Action   string    `json:"action"`
	Target   string    `json:"target,omitempty"`
	Risk     string    `json:"risk"`
	OK       bool      `json:"ok"`
	Message  string    `json:"message"`
	Details  string    `json:"details,omitempty"`
	Duration string    `json:"duration,omitempty"`
}

type doctorCheck struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	State   string `json:"state"`
	Details string `json:"details,omitempty"`
}

type doctorResponse struct {
	OK     bool          `json:"ok"`
	Checks []doctorCheck `json:"checks"`
}

type deployPreviewResponse struct {
	OK             bool     `json:"ok"`
	Valid          bool     `json:"valid"`
	ChangedFiles   []string `json:"changed_files"`
	PlannedActions []string `json:"planned_actions"`
	Details        string   `json:"details,omitempty"`
}

func sanitizeDesiredService(svc Service) sanitizedService {
	return sanitizedService{
		DisplayName:   svc.DisplayName,
		Kind:          svc.Kind,
		Type:          svc.Type,
		Host:          svc.Host,
		Upstream:      svc.Upstream,
		ProxyIdentity: svc.ProxyIdentity,
		Root:          svc.Root,
		APIPath:       svc.APIPath,
		Lifecycle:     svc.Lifecycle,
		Plist:         svc.Plist,
		WorkingDir:    svc.WorkingDir,
		Binary:        svc.Binary,
		Health:        svc.Health,
	}
}
