package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
	"github.com/t-wilkinson/zortex.nvim/app/clocks"
)

// Timers, alarms and the stopwatch, next to the pomodoro on the home page.
// They live in the server (DataDir/clocks.json), so every page and device
// shows the same ones, and a timer or alarm reaches ntfy with no page open.
//
//	GET  /api/clocks                              {timers, alarms, stopwatch, now, ntfy}
//	POST /api/clocks/timers                       {label, seconds}: start a timer
//	POST /api/clocks/timers/{id}/{action}         pause | resume | restart | remove
//	POST /api/clocks/alarms                       {label, time: "HH:MM", repeat: once | daily}
//	POST /api/clocks/alarms/{id}/{action}         enable | disable | remove
//	POST /api/clocks/stopwatch/{action}           start | pause | toggle | lap | reset
//
// POSTs must be JSON or carry the API key, like the pomodoro's.

type clocksView struct {
	clocks.State
	Ntfy bool `json:"ntfy"`
}

func (s *Server) announceClock(e clocks.Event) {
	s.events.publish("clocks", map[string]any{"event": e.Kind, "id": e.ID})
	s.trackSync()
	title, body, tags := clocks.Message(e)
	s.fired.add("clock", title, body, time.Now())
	if !s.cfg.Ntfy.Enabled() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := s.cfg.Ntfy.Publish(ctx, alerts.Message{Title: title, Message: body, Priority: "high", Tags: tags}); err != nil {
		s.log.Printf("%s: ntfy: %v", e.Kind, err)
	}
}

func (s *Server) clocksReady(w http.ResponseWriter) bool {
	if s.clocks == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "no data directory: start zortex serve with -data"})
		return false
	}
	return true
}

func (s *Server) apiClocks(w http.ResponseWriter, r *http.Request) {
	if !s.clocksReady(w) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, clocksView{State: s.clocks.State(), Ntfy: s.cfg.Ntfy.Enabled()})
}

func (s *Server) clocksReply(w http.ResponseWriter, st clocks.State, err error) {
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		status := http.StatusUnprocessableEntity
		if errors.Is(err, clocks.ErrNotFound) {
			status = http.StatusNotFound
		}
		writeJSON(w, status, map[string]any{"error": err.Error(), "state": clocksView{State: st, Ntfy: s.cfg.Ntfy.Enabled()}})
		return
	}
	s.events.publish("clocks", map[string]any{})
	s.trackSync()
	writeJSON(w, http.StatusOK, clocksView{State: st, Ntfy: s.cfg.Ntfy.Enabled()})
}

func (s *Server) clocksPost(w http.ResponseWriter, r *http.Request, body any) bool {
	if !s.clocksReady(w) {
		return false
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
		return false
	}
	if body != nil {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<14)).Decode(body); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
			return false
		}
	}
	return true
}

func (s *Server) apiTimerAdd(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Label   string `json:"label"`
		Seconds int    `json:"seconds"`
	}
	if !s.clocksPost(w, r, &req) {
		return
	}
	st, err := s.clocks.AddTimer(req.Label, req.Seconds)
	s.clocksReply(w, st, err)
}

func (s *Server) apiTimerAction(w http.ResponseWriter, r *http.Request) {
	if !s.clocksPost(w, r, nil) {
		return
	}
	st, err := s.clocks.TimerAction(r.PathValue("id"), r.PathValue("action"))
	s.clocksReply(w, st, err)
}

func (s *Server) apiAlarmAdd(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Label  string `json:"label"`
		Time   string `json:"time"`
		Repeat string `json:"repeat"`
	}
	if !s.clocksPost(w, r, &req) {
		return
	}
	st, err := s.clocks.AddAlarm(req.Label, req.Time, req.Repeat)
	s.clocksReply(w, st, err)
}

func (s *Server) apiAlarmAction(w http.ResponseWriter, r *http.Request) {
	if !s.clocksPost(w, r, nil) {
		return
	}
	st, err := s.clocks.AlarmAction(r.PathValue("id"), r.PathValue("action"))
	s.clocksReply(w, st, err)
}

func (s *Server) apiStopwatch(w http.ResponseWriter, r *http.Request) {
	if !s.clocksPost(w, r, nil) {
		return
	}
	st, err := s.clocks.StopwatchAction(r.PathValue("action"))
	s.clocksReply(w, st, err)
}
