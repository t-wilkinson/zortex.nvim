package web

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
	"github.com/t-wilkinson/zortex.nvim/app/clocks"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/pomodoro"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The calendar: the days of calendar.zortex (read from the notes folder, so
// it shows every entry, timed or not) and the notifications Neovim schedules
// from it (POST /notify), which the sender delivers through ntfy.

// openState opens the notification store and the pomodoro clock in DataDir.
func (s *Server) openState() error {
	store, err := alerts.Open(filepath.Join(s.cfg.DataDir, "notifications.json"))
	if err != nil {
		return fmt.Errorf("notifications: %w", err)
	}
	s.alerts = store
	s.sender = &alerts.Sender{Store: store, Ntfy: s.cfg.Ntfy, Interval: s.cfg.SendInterval, Logger: s.log}
	clock, err := pomodoro.Open(filepath.Join(s.cfg.DataDir, "pomodoro.json"))
	if err != nil {
		return fmt.Errorf("pomodoro: %w", err)
	}
	clock.Notify = func(e pomodoro.Event) {
		s.events.publish("pomodoro", map[string]any{"event": e.Kind})
		s.announcePomodoro(e)
	}
	s.pomo = clock
	cl, err := clocks.Open(filepath.Join(s.cfg.DataDir, "clocks.json"))
	if err != nil {
		return fmt.Errorf("clocks: %w", err)
	}
	cl.Notify = s.announceClock
	s.clocks = cl
	return nil
}

// announcePomodoro sends a phase change through ntfy (the only channel the
// server has, so pomodoro alerts never go anywhere else).
func (s *Server) announcePomodoro(e pomodoro.Event) {
	if !s.cfg.Ntfy.Enabled() {
		return
	}
	title, body, tags := pomodoro.Message(e)
	priority := "high"
	if e.Kind == pomodoro.EventStop {
		priority = "low"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := s.cfg.Ntfy.Publish(ctx, alerts.Message{Title: title, Message: body, Priority: priority, Tags: tags}); err != nil {
		s.log.Printf("pomodoro: ntfy: %v", err)
	}
}

// =============================================================================
// Calendar note
// =============================================================================

var dateLabel = regexp.MustCompile(`^(\d{4})-(\d{2})-(\d{2}):\s*$`)

// calEntry is one list item under a date of the calendar note.
type calEntry struct {
	Lnum   int    `json:"lnum"`
	Time   string `json:"time,omitempty"` // "09:00", or the start of a range
	End    string `json:"end,omitempty"`  // end of a "09:00 - 10:00" range
	Text   string `json:"text"`           // plain text, attributes removed
	HTML   string `json:"html"`           // text with links rendered
	Task   bool   `json:"task,omitempty"`
	Done   bool   `json:"done,omitempty"`
	Depth  int    `json:"depth,omitempty"` // nesting under another entry
	Notify bool   `json:"notify,omitempty"`
	URL    string `json:"url"`
	Src    string `json:"src,omitempty"` // the line as written (-writable: for edits)
	Rel    string `json:"rel,omitempty"`
}

func (s *Server) calendarDoc() *notes.Document {
	if d := s.ix.Doc(s.cfg.Calendar); d != nil {
		return d
	}
	for _, rel := range s.ix.Catalog().WithName("Calendar") {
		if d := s.ix.Doc(rel); d != nil && !s.ix.IsArchived(rel) {
			return d
		}
	}
	return nil
}

// calendarDays: entries by date ("YYYY-MM-DD") for dates in [from, to].
func (s *Server) calendarDays(from, to string) map[string][]calEntry {
	days := map[string][]calEntry{}
	doc := s.calendarDoc()
	if doc == nil {
		return days
	}
	r := &noteRenderer{s: s, doc: doc}
	date := ""
	baseIndent := -1
	for i, line := range doc.Lines {
		lnum := i + 1
		if m := dateLabel.FindStringSubmatch(line); m != nil {
			date, baseIndent = m[1]+"-"+m[2]+"-"+m[3], -1
			continue
		}
		if date == "" || date < from || date > to || doc.InCode(lnum) {
			continue
		}
		it := syntax.ItemOf(line)
		if it == nil {
			continue
		}
		if baseIndent < 0 || it.MarkerCol < baseIndent {
			baseIndent = it.MarkerCol
		}
		e := calEntry{
			Lnum:  lnum,
			Text:  strings.TrimSpace(syntax.StripAttributes(line[it.ContentCol:])),
			HTML:  strings.TrimSpace(r.entryHTML(line, lnum, it.ContentCol)),
			Task:  it.Mark != "",
			Done:  it.Mark == "x" || it.Mark == "X",
			Depth: (it.MarkerCol - baseIndent + 1) / 2,
			URL:   s.noteURL(doc.Rel, lnum),
		}
		if s.cfg.Writable {
			e.Src, e.Rel = line, doc.Rel
		}
		if it.Time != nil {
			e.Time, e.End = it.Time.At, it.Time.To
			if e.Time == "" {
				e.Time = it.Time.From
			}
		}
		days[date] = append(days[date], e)
	}
	return days
}

// entryHTML renders line[from:] like a note line, without attributes.
func (r *noteRenderer) entryHTML(line string, lnum, from int) string {
	spans := append([]syntax.Span(nil), r.doc.Spans(lnum)...)
	for i := range spans {
		if spans[i].Type == "attribute" {
			spans[i].Type = "hidden"
		}
	}
	return r.inline(line, spans, from, len(line))
}

// =============================================================================
// API
// =============================================================================

// apiCalendar: GET /api/calendar?from=&to=
//
//	days           {date: [entry]} from calendar.zortex (default: 45 days back, 120 ahead)
//	notifications  scheduled notifications from 30 days ago on
//	count          pending notifications
//	next_event     "HH:MM title" of the next notification
//	events, text_view   the old server's fields (dashboards)
func (s *Server) apiCalendar(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	from, to := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	if !isDate(from) {
		from = now.AddDate(0, 0, -45).Format("2006-01-02")
	}
	if !isDate(to) {
		to = now.AddDate(0, 0, 120).Format("2006-01-02")
	}
	days := s.calendarDays(from, to)
	view := s.notificationView(now)
	// mark entries that have a notification on their day
	for date, list := range days {
		for i := range list {
			list[i].Notify = view.notified[date+"\x00"+list[i].Text]
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from":          from,
		"to":            to,
		"today":         now.Format("2006-01-02"),
		"days":          days,
		"notifications": view.events,
		"events":        view.events,
		"count":         view.pending,
		"next_event":    view.next,
		"next_time":     view.nextTime,
		"text_view":     view.text,
		"notes_enabled": s.alerts != nil,
		"writable":      s.cfg.Writable,
		"ntfy":          s.cfg.Ntfy.Enabled(),
	})
}

func isDate(s string) bool {
	_, err := time.Parse("2006-01-02", s)
	return err == nil
}

type notifEvent struct {
	ID        int64  `json:"id"`
	DateStr   string `json:"date_str"`
	TimeStr   string `json:"time_str"`
	Title     string `json:"title"`
	Message   string `json:"message"`
	Timestamp int64  `json:"timestamp"`
	IsPast    bool   `json:"is_past"`
	IsCurrent bool   `json:"is_current"`
	Sent      bool   `json:"sent"`
}

type notifView struct {
	events   []notifEvent
	pending  int
	next     string
	nextTime int64
	text     string
	notified map[string]bool // date + "\x00" + entry text
}

// notificationView: the scheduled notifications as the calendar shows them.
func (s *Server) notificationView(now time.Time) notifView {
	v := notifView{events: []notifEvent{}, next: "No events", notified: map[string]bool{}}
	if s.alerts == nil {
		return v
	}
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	list := s.alerts.Since(day.AddDate(0, 0, -30))
	current := int64(-1)
	for _, n := range list {
		if n.ScheduledTime <= now.Unix() {
			current = n.ID
		}
	}
	var text []string
	lastDate := ""
	for _, n := range list {
		t := time.Unix(n.ScheduledTime, 0).In(now.Location())
		ev := notifEvent{
			ID: n.ID, DateStr: t.Format("2006-01-02"), TimeStr: t.Format("15:04"),
			Title: strings.TrimPrefix(n.Title, "Calendar: "), Message: n.Message, Timestamp: n.ScheduledTime,
			IsCurrent: n.ID == current, IsPast: n.ScheduledTime < now.Unix() && n.ID != current, Sent: !n.Pending(),
		}
		v.events = append(v.events, ev)
		if n.EntryID != "" {
			v.notified[ev.DateStr+"\x00"+n.EntryID] = true
		}
		if n.Pending() {
			v.pending++
		}
		if n.ScheduledTime > now.Unix() && v.nextTime == 0 {
			v.next, v.nextTime = ev.TimeStr+" "+ev.Title, n.ScheduledTime
		}
		if n.ScheduledTime >= day.Unix() {
			if ev.DateStr != lastDate {
				if lastDate != "" {
					text = append(text, "")
				}
				text = append(text, ev.DateStr+":")
				lastDate = ev.DateStr
			}
			mark := "    "
			if ev.IsCurrent {
				mark = "  ▶ "
			}
			text = append(text, mark+ev.TimeStr+" "+ev.Title)
		}
	}
	v.text = strings.Join(text, "\n")
	return v
}

// apiSummary: GET /api/summary, for homelab dashboards.
func (s *Server) apiSummary(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	v := s.notificationView(now)
	out := map[string]any{
		"status":        "ok",
		"pending_count": v.pending,
		"calendar_text": v.text,
		"calendar_html": "<pre>" + html.EscapeString(v.text) + "</pre>",
		"next_event":    v.next,
		"generated_at":  now.Format(time.RFC3339),
	}
	if s.pomo != nil {
		st := s.pomo.State()
		out["pomodoro"] = map[string]any{"phase": st.Phase, "running": st.Running, "remaining": st.Remaining, "today": st.Today}
	}
	writeJSON(w, http.StatusOK, out)
}

// keyOK checks the X-API-Key header when an API key is configured.
func (s *Server) keyOK(r *http.Request) bool {
	if s.cfg.APIKey == "" {
		return true
	}
	return subtle.ConstantTimeCompare([]byte(r.Header.Get("X-API-Key")), []byte(s.cfg.APIKey)) == 1
}

func (s *Server) stateEnabled(w http.ResponseWriter) bool {
	if s.alerts == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"success": false, "error": "no data directory: start zortex serve with -data"})
		return false
	}
	return true
}

// handleNotify: POST /notify, the notification API Neovim talks to.
//
//	{user_id, operation: "sync", notifications: [...]}   replace pending notifications
//	{user_id, operation: "notify", notification: {...}}  add one
//	{user_id, operation: "clear"}                        remove pending ones
func (s *Server) handleNotify(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"success": false, "error": "bad API key"})
		return
	}
	if !s.stateEnabled(w) {
		return
	}
	var req struct {
		UserID        string            `json:"user_id"`
		Operation     string            `json:"operation"`
		Notifications []alerts.Incoming `json:"notifications"`
		Notification  alerts.Incoming   `json:"notification"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "error": "invalid JSON: " + err.Error()})
		return
	}
	if req.UserID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "error": "user_id required"})
		return
	}
	switch req.Operation {
	case "sync":
		res, err := s.alerts.Sync(req.UserID, req.Notifications)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "error": err.Error()})
			return
		}
		if !res.Unchanged {
			s.log.Printf("notifications: sync %s: %d added, %d updated, %d removed", req.UserID, res.Added, res.Updated, res.Removed)
		}
		s.sender.Kick()
		writeJSON(w, http.StatusOK, res)
	case "notify":
		n, added, err := s.alerts.Add(req.UserID, req.Notification)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "error": err.Error()})
			return
		}
		s.sender.Kick()
		out := map[string]any{"success": true, "id": n.ID}
		if !added {
			out["message"] = "Duplicate notification skipped"
		}
		writeJSON(w, http.StatusOK, out)
	case "clear":
		n, err := s.alerts.Clear(req.UserID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "deleted": n})
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "error": "Unknown operation: " + req.Operation})
	}
}

// handlePending: GET /pending?user_id=
func (s *Server) handlePending(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"success": false, "error": "bad API key"})
		return
	}
	if !s.stateEnabled(w) {
		return
	}
	type out struct {
		alerts.Notification
		ScheduledDatetime string `json:"scheduled_datetime"`
	}
	list := []out{}
	for _, n := range s.alerts.Pending(r.URL.Query().Get("user_id")) {
		list = append(list, out{n, time.Unix(n.ScheduledTime, 0).UTC().Format(time.RFC3339)})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].ScheduledTime < list[j].ScheduledTime })
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "count": len(list), "notifications": list})
}

// handleTestNotification: POST /test {title?, message?} publishes through
// ntfy right away and reports the result.
func (s *Server) handleTestNotification(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"success": false, "error": "bad API key"})
		return
	}
	var req struct{ Title, Message string }
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req)
	if req.Title == "" {
		req.Title = "Test Notification"
	}
	if req.Message == "" {
		req.Message = "This is a test at " + time.Now().Format(time.RFC3339)
	}
	if !s.cfg.Ntfy.Enabled() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"success": false, "error": "ntfy is not configured (-ntfy-url, -ntfy-topic)"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if err := s.cfg.Ntfy.Publish(ctx, alerts.Message{Title: req.Title, Message: req.Message, Priority: "high", Tags: []string{"test"}}); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"success": false, "error": err.Error(), "test_results": map[string]any{"overall_status": "FAILED"}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "test_results": map[string]any{"notification_sent": true, "overall_status": "SUCCESS"}})
}
