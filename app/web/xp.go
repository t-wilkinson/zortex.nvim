package web

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
)

// XP lives in Neovim (lua/zortex/services/xp/ledger: it is read off the
// notes there). After every change Neovim publishes a small summary, both
// into the synced notes folder (.z/xp_summary.json) and, when it talks to
// this server, as POST /api/xp. The home page shows the newer of the two.
//
//	GET  /api/xp   the summary, or {"available": false}
//	POST /api/xp   store a summary (X-API-Key when -api-key is set)

const xpFile = "xp_summary.json"

type xpCache struct {
	mu     sync.Mutex
	posted []byte // last POSTed summary (also in DataDir)
	// the notes folder's copy, re-read when its mtime changes
	fileMod  time.Time
	fileBody []byte
}

// generated reads the summary's "generated" time (zero when missing).
func generated(raw []byte) time.Time {
	var head struct {
		Generated time.Time `json:"generated"`
	}
	if json.Unmarshal(raw, &head) != nil {
		return time.Time{}
	}
	return head.Generated
}

func (s *Server) xpSummary() []byte {
	c := &s.xp
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.posted == nil && s.cfg.DataDir != "" {
		if raw, err := os.ReadFile(filepath.Join(s.cfg.DataDir, xpFile)); err == nil {
			c.posted = raw
		}
	}
	path := filepath.Join(s.cfg.Root, ".z", xpFile)
	if st, err := os.Stat(path); err == nil {
		if !st.ModTime().Equal(c.fileMod) {
			if raw, err := os.ReadFile(path); err == nil && json.Valid(raw) {
				c.fileBody, c.fileMod = raw, st.ModTime()
			}
		}
	} else {
		c.fileBody, c.fileMod = nil, time.Time{}
	}
	switch {
	case c.posted == nil:
		return c.fileBody
	case c.fileBody == nil:
		return c.posted
	case generated(c.fileBody).After(generated(c.posted)):
		return c.fileBody
	}
	return c.posted
}

func (s *Server) apiXP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	raw := s.xpSummary()
	out := map[string]json.RawMessage{}
	if raw == nil || json.Unmarshal(raw, &out) != nil {
		out = map[string]json.RawMessage{"available": json.RawMessage("false")}
	}
	// tasks completed on the web since Neovim last counted XP, with the XP
	// they are estimated to earn (Neovim's calibration)
	pending := s.pendingCompletions(generated(raw))
	cal := calibrationOf(raw)
	titles := []string{}
	type pendingTask struct {
		Title string  `json:"title"`
		XP    float64 `json:"xp"`
		Hours float64 `json:"hours"`
	}
	tasks := []pendingTask{}
	total, totalHours := 0.0, 0.0
	for i, p := range pending {
		h := cal.hours(p.Size)
		if p.Hours > 0 {
			h = p.Hours // a share of a task group
		}
		xp := cal.taskHoursXP(h, p.P, p.I)
		total += xp
		totalHours += h
		if i < 5 {
			titles = append(titles, p.Title)
			tasks = append(tasks, pendingTask{Title: p.Title, XP: math.Round(xp*10) / 10, Hours: h})
		}
	}
	out["pending_web"], _ = json.Marshal(len(pending))
	out["pending_titles"], _ = json.Marshal(titles)
	out["pending_tasks"], _ = json.Marshal(tasks)
	out["pending_xp"], _ = json.Marshal(math.Round(total))
	out["pending_hours"], _ = json.Marshal(math.Round(totalHours*100) / 100)
	writeJSON(w, http.StatusOK, out)
}

// =============================================================================
// Estimating XP the way Neovim does (services/xp/calculator)
// =============================================================================

// calibration is how Neovim turns a task into XP: @size -> hours, XP per
// hour, priority and importance multipliers. The XP summary carries it;
// without one the plugin's defaults apply.
type calibration struct {
	XPPerHour   float64            `json:"xp_per_hour"`
	TaskHours   map[string]float64 `json:"task_hours"`
	DefaultSize string             `json:"default_size"`
	Priority    map[string]float64 `json:"priority"`
	Importance  map[string]float64 `json:"importance"`
}

func defaultCalibration() calibration {
	return calibration{
		XPPerHour: 10,
		TaskHours: map[string]float64{
			"xs": 0.25, "sm": 0.5, "md": 1, "lg": 2, "xl": 3,
			"2xl": 5, "3xl": 8, "4xl": 13, "5xl": 20,
		},
		DefaultSize: "md",
		Priority:    map[string]float64{"1": 1.5, "2": 1.2, "3": 1},
		Importance:  map[string]float64{"1": 1.5, "2": 1.2, "3": 1},
	}
}

// calibrationOf: the summary's calibration over the defaults.
func calibrationOf(raw []byte) calibration {
	c := defaultCalibration()
	var head struct {
		Calibration *calibration `json:"calibration"`
	}
	if raw == nil || json.Unmarshal(raw, &head) != nil || head.Calibration == nil {
		return c
	}
	got := head.Calibration
	if got.XPPerHour > 0 {
		c.XPPerHour = got.XPPerHour
	}
	if got.DefaultSize != "" {
		c.DefaultSize = got.DefaultSize
	}
	for k, v := range got.TaskHours {
		if v > 0 {
			c.TaskHours[k] = v
		}
	}
	for k, v := range got.Priority {
		c.Priority[k] = v
	}
	for k, v := range got.Importance {
		c.Importance[k] = v
	}
	return c
}

// hours of a task @size (unsized or unknown: the default size)
func (c calibration) hours(size string) float64 {
	if h, ok := c.TaskHours[strings.ToLower(size)]; ok {
		return h
	}
	if h, ok := c.TaskHours[c.DefaultSize]; ok {
		return h
	}
	return 1
}

// groups: the task groups of lines[first..last] with this calibration's
// sizes (edit.Groups).
func (c calibration) groups(lines []string, first, last int) map[int]*edit.GroupTask {
	return edit.Groups(lines, first, last, func(size string) (float64, bool) {
		h, ok := c.TaskHours[strings.ToLower(size)]
		return h, ok
	}, c.hours(""))
}

// taskXP: hours x XP per hour x priority x importance.
func (c calibration) taskXP(size, p, i string) float64 {
	return c.taskHoursXP(c.hours(size), p, i)
}

// taskHoursXP: taskXP for a number of hours (a share of a task group).
func (c calibration) taskHoursXP(hours float64, p, i string) float64 {
	xp := hours * c.XPPerHour
	if m, ok := c.Priority[p]; ok && p != "" {
		xp *= m
	}
	if m, ok := c.Importance[i]; ok && i != "" {
		xp *= m
	}
	return xp
}

// calibration: the current summary's (for project progress).
func (s *Server) calibration() calibration { return calibrationOf(s.xpSummary()) }

func (s *Server) apiXPPost(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"success": false, "error": "bad API key"})
		return
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"success": false, "error": "send JSON"})
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"success": false, "error": err.Error()})
		return
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "error": "invalid JSON: " + err.Error()})
		return
	}
	if _, ok := obj["generated"]; !ok {
		// stamp it so the newest copy wins
		obj["generated"], _ = json.Marshal(time.Now().UTC())
	}
	obj["available"] = json.RawMessage("true")
	var buf bytes.Buffer
	_ = json.NewEncoder(&buf).Encode(obj)
	body := bytes.TrimSpace(buf.Bytes())
	s.xp.mu.Lock()
	s.xp.posted = body
	s.xp.mu.Unlock()
	defer s.events.publish("xp", map[string]any{})
	if s.cfg.DataDir != "" {
		path := filepath.Join(s.cfg.DataDir, xpFile)
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, body, 0o640); err == nil {
			_ = os.Rename(tmp, path)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
