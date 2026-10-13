package web

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/pomodoro"
)

// The pomodoro clock lives in the server, so Neovim (:ZortexPomodoro…) and
// the home page drive the same clock and either can be closed.
//
//	GET  /api/pomodoro                 state
//	POST /api/pomodoro/{action}        start | pause | resume | toggle | skip | stop | restart
//	POST /api/pomodoro/settings        {work, short_break, long_break, long_break_after, auto_start_break, auto_start_work}
//
// POSTs must be JSON (Content-Type: application/json) or carry the API key:
// a cross-site form can't send either, so another site can't drive the clock.

type pomodoroView struct {
	pomodoro.State
	Enabled   bool       `json:"enabled"`
	Ntfy      bool       `json:"ntfy"`       // phase changes are announced through ntfy
	PhaseName string     `json:"phase_name"` // "Work", "Short break", ...
	NextAlarm *time.Time `json:"next_alarm"` // when the running phase ends
}

func (s *Server) pomodoroView(st pomodoro.State) pomodoroView {
	v := pomodoroView{State: st, Enabled: true, Ntfy: s.cfg.Ntfy.Enabled(), PhaseName: pomodoro.PhaseName(st.Phase)}
	if st.Running {
		t := st.EndsAt
		v.NextAlarm = &t
	}
	return v
}

func (s *Server) apiPomodoro(w http.ResponseWriter, r *http.Request) {
	if s.pomo == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "phase": pomodoro.Idle})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.pomodoroView(s.pomo.State()))
}

// jsonOrKey: the request is JSON (needs a CORS preflight cross-site) or
// carries a valid API key.
func (s *Server) jsonOrKey(r *http.Request) bool {
	if s.cfg.APIKey != "" && r.Header.Get("X-API-Key") != "" {
		return s.keyOK(r)
	}
	mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return mt == "application/json"
}

func (s *Server) apiPomodoroAction(w http.ResponseWriter, r *http.Request) {
	if s.pomo == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "no data directory: start zortex serve with -data"})
		return
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
		return
	}
	var (
		st  pomodoro.State
		err error
	)
	switch r.PathValue("action") {
	case "start":
		st, err = s.pomo.Start()
	case "pause":
		st, err = s.pomo.Pause()
	case "resume":
		st, err = s.pomo.Resume()
	case "toggle":
		st, err = s.pomo.Toggle()
	case "skip":
		st, err = s.pomo.Skip()
	case "stop":
		st, err = s.pomo.Stop()
	case "restart":
		st, err = s.pomo.Restart()
	case "settings":
		cur := s.pomo.State().Settings
		if derr := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(&cur); derr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + derr.Error()})
			return
		}
		st, err = s.pomo.Update(cur)
	default:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "unknown action " + r.PathValue("action")})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		status := http.StatusConflict
		var perr *json.SyntaxError
		if errors.As(err, &perr) {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, map[string]any{"error": err.Error(), "state": s.pomodoroView(st)})
		return
	}
	s.events.publish("pomodoro", map[string]any{})
	writeJSON(w, http.StatusOK, s.pomodoroView(st))
}
