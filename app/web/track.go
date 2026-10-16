package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

// Time tracking (-writable with -data): while a clock runs (a pomodoro work
// phase, the stopwatch, a timer) the time goes to the task you're working
// on, added to its @spent(1h25m) when the clocks stop or the task changes
// (app/tracker has the rules). The task is the current calendar entry (or
// the task its link points at), or one picked on the home page or from a
// note's Edit toolbar.
//
//	GET  /api/track                  {enabled, mode, task, counted_ms, ...}
//	POST /api/track/pin              {rel, lnum, expect}: work on this line
//	POST /api/track/follow           follow the calendar again
//	POST /api/track/off              track nothing
//	GET  /api/track/tasks?q=         open tasks matching q (the picker)

const trackLog = "track_log.jsonl"

// ---------------------------------------------------------------------------
// Durations: "1h25m", "45m", "2h" (minutes, as the plugin reads them)
// ---------------------------------------------------------------------------

var durationPart = regexp.MustCompile(`(\d+(?:\.\d+)?)\s*([hdmw])`)

// parseMinutes reads a duration as the plugin does (m, h, d, w); ok is
// false when the text has none.
func parseMinutes(s string) (float64, bool) {
	total, found := 0.0, false
	for _, m := range durationPart.FindAllStringSubmatch(s, -1) {
		n, err := strconv.ParseFloat(m[1], 64)
		if err != nil {
			continue
		}
		found = true
		switch m[2] {
		case "m":
			total += n
		case "h":
			total += n * 60
		case "d":
			total += n * 60 * 24
		case "w":
			total += n * 60 * 24 * 7
		}
	}
	return total, found
}

// formatMinutes: 85 -> "1h25m", 45 -> "45m", 120 -> "2h".
func formatMinutes(min int) string {
	h, m := min/60, min%60
	switch {
	case h == 0:
		return fmt.Sprintf("%dm", m)
	case m == 0:
		return fmt.Sprintf("%dh", h)
	}
	return fmt.Sprintf("%dh%dm", h, m)
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

func lineText(line string) string {
	col := 0
	if d := syntax.Classify(line); d.ContentCol != nil {
		col = *d.ContentCol
	}
	if col > len(line) {
		col = len(line)
	}
	return strings.TrimSpace(syntax.StripAttributes(line[col:]))
}

// targetFor describes line lnum of doc as something to track.
func targetFor(doc *notes.Document, lnum int) *tracker.Target {
	if doc == nil || lnum < 1 || lnum > len(doc.Lines) {
		return nil
	}
	line := doc.Lines[lnum-1]
	t := &tracker.Target{Rel: doc.Rel, Lnum: lnum, Line: line, Text: lineText(line)}
	if id, ok := edit.Attribute(line, "id"); ok && id != "" {
		t.ID = id
		t.Key = doc.Rel + "#" + id
	} else {
		t.Key = doc.Rel + "|" + t.Text
	}
	return t
}

// findTarget: where t's line is now in lines (by @id, else by its text,
// nearest to where it was), or -1.
func findTarget(lines []string, t tracker.Target) int {
	best := -1
	for i, l := range lines {
		if t.ID != "" {
			if strings.Contains(l, "@id("+t.ID+")") {
				return i
			}
			continue
		}
		if lineText(l) != t.Text {
			continue
		}
		if best < 0 || abs(i+1-t.Lnum) < abs(best+1-t.Lnum) {
			best = i
		}
	}
	return best
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// calendarTarget: what the current calendar entry means to work on: the
// first open task nested under it (mirrors.go blockTask), else the task its
// first link points at when that is a task, else the entry itself. nil when
// no timed entry is running now.
func (s *Server) calendarTarget(now time.Time) *tracker.Target {
	doc := s.calendarDoc()
	if doc == nil {
		return nil
	}
	today := now.Format("2006-01-02")
	entries := s.calendarDays(today, today)[today]
	nowMin := now.Hour()*60 + now.Minute()
	var cur *calEntry
	for i := range entries {
		m, ok := clockMinutes(entries[i].Time)
		if !ok {
			continue
		}
		if m <= nowMin {
			cur = &entries[i]
		}
	}
	if cur == nil {
		return nil
	}
	if cur.End != "" {
		start, _ := clockMinutes(cur.Time)
		if end, ok := clockMinutes(cur.End); ok && end > start && nowMin >= end {
			return nil
		}
	}
	// a block with tasks under it ("09:00 [P/#1.4 - zortex]"): the first open one
	if t := s.blockTask(doc, cur.Lnum); t != nil {
		return t
	}
	// a project block with nothing under it: the project's next open task
	if bt := s.projectBlock(doc, cur.Lnum, s.allProjects()); len(bt) > 0 {
		if pd := s.ix.Doc(bt[0].project.Rel); pd != nil {
			return targetFor(pd, bt[0].task.Lnum)
		}
	}
	if !cur.Task || cur.Ref != "" { // a reference stands for the task it links
		var target *tracker.Target
		syntax.Walk(doc.Spans(cur.Lnum), func(sp *syntax.Span) {
			if target != nil || sp.Type != "link" || s.fileLike(sp.Definition) {
				return
			}
			r, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: doc, Lnum: cur.Lnum})
			if err != nil || r == nil {
				return
			}
			if it := syntax.ItemOf(r.Doc.Lines[r.Lnum-1]); it != nil && it.Mark != "" {
				target = targetFor(r.Doc, r.Lnum)
			}
		})
		if target != nil {
			return target
		}
	}
	return targetFor(doc, cur.Lnum)
}

func clockMinutes(hm string) (int, bool) {
	var h, m int
	if _, err := fmt.Sscanf(hm, "%d:%d", &h, &m); err != nil {
		return 0, false
	}
	return h*60 + m, true
}

// clocksRunning: whether a clock counts now, and when the running ones end.
func (s *Server) clocksRunning() tracker.Clocks {
	var c tracker.Clocks
	open := false
	consider := func(end time.Time) {
		c.Running = true
		if end.IsZero() {
			open = true
		} else if end.After(c.Bound) {
			c.Bound = end
		}
	}
	if s.pomo != nil {
		if st := s.pomo.State(); st.Running && st.Phase == "work" {
			consider(st.EndsAt)
		}
	}
	if s.clocks != nil {
		st := s.clocks.State()
		if st.Stopwatch.Running {
			consider(time.Time{})
		}
		for _, t := range st.Timers {
			if t.Running {
				consider(t.EndsAt)
			}
		}
	}
	if open {
		c.Bound = time.Time{}
	}
	return c
}

// ---------------------------------------------------------------------------
// Writing @spent
// ---------------------------------------------------------------------------

func (s *Server) writeSpent(t tracker.Target, minutes int) (tracker.Target, error) {
	s.editMu.Lock()
	f, err := readNoteFile(s.ix.Path(t.Rel))
	if err != nil {
		s.editMu.Unlock()
		return t, fmt.Errorf("%s: %w", t.Rel, err)
	}
	i := findTarget(f.lines, t)
	if i < 0 {
		s.editMu.Unlock()
		return t, fmt.Errorf("%q is no longer in %s", t.Text, t.Rel)
	}
	line := f.lines[i]
	total := float64(minutes)
	if v, ok := edit.Attribute(line, "spent"); ok {
		if prev, ok := parseMinutes(v); ok {
			total += prev
		}
	}
	f.lines[i] = edit.UpdateAttribute(line, "spent", formatMinutes(int(total+0.5)))
	err = f.write()
	s.editMu.Unlock()
	if err != nil {
		return t, err
	}
	// the index sees the change now; open pages get a "notes" event
	_, rels := s.ix.ScanChanges()
	go s.rebuild(s.scanResources())
	s.notesChanged(rels)
	s.log.Printf("track: %s +%dm on %s:%d", t.Text, minutes, t.Rel, i+1)
	if doc := s.ix.Doc(t.Rel); doc != nil {
		if nt := targetFor(doc, i+1); nt != nil {
			nt.Key = t.Key // same task, though its text may read differently now
			return *nt, nil
		}
	}
	t.Line, t.Lnum = f.lines[i], i+1
	return t, nil
}

func (s *Server) logTrack(e tracker.Entry) {
	if err := s.addTimeSpent(e); err != nil {
		s.log.Printf("track: .z/%s: %v", timeSpentFile, err)
	}
	if s.cfg.DataDir == "" {
		return
	}
	raw, err := json.Marshal(e)
	if err != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(s.cfg.DataDir, trackLog), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return
	}
	defer f.Close()
	f.Write(append(raw, '\n'))
}

// trackSync brings the tracker up to date with the clocks and the calendar.
// Called after every clock change, rescan and on a ticker; never while the
// tracker is writing (writeSpent doesn't call it).
func (s *Server) trackSync() {
	if !s.tracking() {
		return
	}
	before := s.track.State()
	after, err := s.track.Sync(s.clocksRunning(), s.calendarTarget(time.Now()))
	if err != nil {
		s.log.Printf("track: %v", err)
	}
	if trackChanged(before, after) {
		s.events.publish("track", map[string]any{})
	}
}

func trackChanged(a, b tracker.State) bool {
	key := func(st tracker.State) string {
		k := ""
		if st.Task != nil {
			k = st.Task.Key + st.Task.Line
		}
		return fmt.Sprint(st.Mode, k, st.Pending, st.Since.UnixNano(), st.Error)
	}
	return key(a) != key(b)
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

type trackTask struct {
	Rel     string `json:"rel"`
	Lnum    int    `json:"lnum"`
	Text    string `json:"text"`
	HTML    string `json:"html"`
	URL     string `json:"url"`
	Where   string `json:"where"`             // note › section
	Spent   int    `json:"spent_min"`         // @spent so far
	Done    bool   `json:"done,omitempty"`    //
	Current bool   `json:"current,omitempty"` // the one being tracked
}

func (s *Server) trackTaskView(t *tracker.Target) *trackTask {
	if t == nil {
		return nil
	}
	v := &trackTask{Rel: t.Rel, Lnum: t.Lnum, Text: t.Text, URL: s.noteURL(t.Rel, t.Lnum)}
	doc := s.ix.Doc(t.Rel)
	if doc == nil {
		return v
	}
	if i := findTarget(doc.Lines, *t); i >= 0 {
		v.Lnum, v.URL = i+1, s.noteURL(t.Rel, i+1)
		s.fillTask(v, doc, i+1)
	}
	return v
}

func (s *Server) fillTask(v *trackTask, doc *notes.Document, lnum int) {
	line := doc.Lines[lnum-1]
	if sp, ok := edit.Attribute(line, "spent"); ok {
		if m, ok := parseMinutes(sp); ok {
			v.Spent = int(m + 0.5)
		}
	}
	if it := syntax.ItemOf(line); it != nil {
		v.Done = it.Mark == "x" || it.Mark == "X"
		r := &noteRenderer{s: s, doc: doc}
		v.HTML = strings.TrimSpace(r.entryHTML(line, lnum, it.ContentCol))
	}
	where := doc.Title()
	if n := doc.NodeAt(lnum); n != nil && !n.IsRoot() {
		where = n.Breadcrumb(" › ")
	}
	v.Where = where
}

// tracking: time tracking needs somewhere to keep its state (-data) and
// leave to write @spent (-writable).
func (s *Server) tracking() bool { return s.track != nil && s.cfg.Writable }

func (s *Server) trackView() map[string]any {
	if !s.tracking() {
		reason := "start zortex serve with -writable to track time on tasks"
		if s.cfg.DataDir == "" {
			reason = "start zortex serve with -data and -writable to track time on tasks"
		}
		return map[string]any{"enabled": false, "reason": reason}
	}
	st := s.track.State()
	out := map[string]any{
		"enabled":    true,
		"mode":       st.Mode,
		"task":       s.trackTaskView(st.Task),
		"counted_ms": st.Counted,
		"counting":   !st.Since.IsZero(),
		"error":      st.Error,
		"now":        st.Now,
		"min_write":  int(tracker.MinWrite / time.Second),
	}
	if st.Mode != tracker.ModeCalendar {
		out["calendar"] = s.trackTaskView(s.calendarTarget(time.Now()))
	}
	return out
}

func (s *Server) apiTrack(w http.ResponseWriter, r *http.Request) {
	s.trackSync()
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.trackView())
}

func (s *Server) trackPost(w http.ResponseWriter, r *http.Request) bool {
	if !s.tracking() {
		writeJSON(w, http.StatusServiceUnavailable, s.trackView())
		return false
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
		return false
	}
	return true
}

func (s *Server) trackReply(w http.ResponseWriter, err error) {
	s.events.publish("track", map[string]any{})
	out := s.trackView()
	if err != nil {
		out["error"] = err.Error()
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) apiTrackPin(w http.ResponseWriter, r *http.Request) {
	if !s.trackPost(w, r) {
		return
	}
	var req struct {
		Rel    string `json:"rel"`
		Lnum   int    `json:"lnum"`
		Expect string `json:"expect"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return
	}
	doc := s.ix.Doc(req.Rel)
	if doc == nil || req.Lnum < 1 || req.Lnum > len(doc.Lines) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such line"})
		return
	}
	if req.Expect != "" && doc.Lines[req.Lnum-1] != req.Expect {
		writeJSON(w, http.StatusConflict, map[string]any{"error": errChanged.Error()})
		return
	}
	if lnum := req.Lnum; lnum <= doc.Header().LastLnum || strings.TrimSpace(doc.Lines[lnum-1]) == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "pick a task or a line of text"})
		return
	}
	_, err := s.track.Pin(*targetFor(doc, req.Lnum))
	s.trackSync() // a clock may be running: count from now
	s.trackReply(w, err)
}

func (s *Server) apiTrackMode(w http.ResponseWriter, r *http.Request) {
	if !s.trackPost(w, r) {
		return
	}
	var err error
	switch r.PathValue("mode") {
	case "follow":
		_, err = s.track.Follow(s.calendarTarget(time.Now()))
	case "off":
		_, err = s.track.Off()
	case "flush":
		_, err = s.track.Flush()
	default:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "unknown action"})
		return
	}
	s.trackSync()
	s.trackReply(w, err)
}

// apiTrackTasks: open tasks whose text, note or section match every word of
// q (all open tasks without q), newest notes first; at most 40.
func (s *Server) apiTrackTasks(w http.ResponseWriter, r *http.Request) {
	words := strings.Fields(strings.ToLower(r.URL.Query().Get("q")))
	type hit struct {
		v   trackTask
		mod time.Time
	}
	var hits []hit
	var current *tracker.Target
	if s.tracking() {
		current = s.track.State().Task
	}
	for _, rel := range s.ix.All() {
		doc := s.ix.Doc(rel)
		if doc == nil || s.ix.IsArchived(rel) {
			continue
		}
		for i, line := range doc.Lines {
			lnum := i + 1
			it := syntax.ItemOf(line)
			if it == nil || it.Mark != " " || doc.InCode(lnum) {
				continue
			}
			text := lineText(line)
			if text == "" {
				continue
			}
			hay := strings.ToLower(text + " " + doc.Title() + " " + rel)
			if n := doc.NodeAt(lnum); n != nil && !n.IsRoot() {
				hay += " " + strings.ToLower(n.Breadcrumb(" "))
			}
			ok := true
			for _, w := range words {
				if !strings.Contains(hay, w) {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			v := trackTask{Rel: rel, Lnum: lnum, Text: text, URL: s.noteURL(rel, lnum)}
			s.fillTask(&v, doc, lnum)
			if t := targetFor(doc, lnum); current != nil && tracker.Same(t, current) {
				v.Current = true
			}
			hits = append(hits, hit{v, doc.ModTime})
		}
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].mod.After(hits[j].mod) })
	out := []trackTask{}
	for i, h := range hits {
		if i == 40 {
			break
		}
		out = append(out, h.v)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"tasks": out, "more": len(hits) > len(out)})
}
