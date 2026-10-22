package web

import (
	"net/http"
	"strconv"
	"sync"
	"time"
)

// The alerts the server raises, as they happen: a calendar notification
// coming due (alerts.Sender), a pomodoro phase change, a timer or alarm
// going off. ntfy carries them to phones and desktops; Neovim asks for them
// here and shows them in the editor.
//
//	GET /api/alerts            {seq, alerts: []}: where the list is now
//	GET /api/alerts?after=N    {seq, alerts: [{seq, kind, title, message, at}]}
//	                           the ones after N (X-API-Key when -api-key is set)
//
// The list lives in memory and keeps the last maxFiredAlerts.

const maxFiredAlerts = 100

type firedAlert struct {
	Seq     int64  `json:"seq"`
	Kind    string `json:"kind"` // "calendar" | "pomodoro" | "clock"
	Title   string `json:"title"`
	Message string `json:"message"`
	At      int64  `json:"at"` // unix seconds
}

type firedAlerts struct {
	mu   sync.Mutex
	seq  int64
	list []firedAlert
}

func (f *firedAlerts) add(kind, title, message string, at time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq++
	f.list = append(f.list, firedAlert{Seq: f.seq, Kind: kind, Title: title, Message: message, At: at.Unix()})
	if len(f.list) > maxFiredAlerts {
		f.list = f.list[len(f.list)-maxFiredAlerts:]
	}
}

// after: the alerts after seq n, and the latest seq.
func (f *firedAlerts) after(n int64) ([]firedAlert, int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := []firedAlert{}
	for _, a := range f.list {
		if a.Seq > n {
			out = append(out, a)
		}
	}
	return out, f.seq
}

func (s *Server) apiAlerts(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "bad API key"})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	q := r.URL.Query().Get("after")
	if q == "" {
		_, seq := s.fired.after(1 << 62)
		writeJSON(w, http.StatusOK, map[string]any{"seq": seq, "alerts": []firedAlert{}})
		return
	}
	n, err := strconv.ParseInt(q, 10, 64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "after: a number"})
		return
	}
	list, seq := s.fired.after(n)
	writeJSON(w, http.StatusOK, map[string]any{"seq": seq, "alerts": list})
}
