package web

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"github.com/t-wilkinson/zortex.nvim/app/feeds"
	"html"
	"net/http"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/alerts"
	"github.com/t-wilkinson/zortex.nvim/app/clocks"
	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/pomodoro"
	"github.com/t-wilkinson/zortex.nvim/app/search"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
	"github.com/t-wilkinson/zortex.nvim/app/tracker"
)

// The calendar: the days of calendar.zortex (read from the notes folder, so
// it shows every entry, timed or not) and the notifications Neovim schedules
// from it (POST /api/notifications/sync), which the sender delivers through ntfy.

// openState opens the notification store and the pomodoro clock in DataDir.
func (s *Server) openState() error {
	store, err := alerts.Open(filepath.Join(s.cfg.DataDir, "notifications.json"))
	if err != nil {
		return fmt.Errorf("notifications: %w", err)
	}
	s.alerts = store
	s.sender = &alerts.Sender{Store: store, Ntfy: s.cfg.Ntfy, Interval: s.cfg.SendInterval, Logger: s.log,
		OnFire: func(n alerts.Notification) { s.fired.add("calendar", n.Title, n.Message, time.Now()) }}
	clock, err := pomodoro.Open(filepath.Join(s.cfg.DataDir, "pomodoro.json"))
	if err != nil {
		return fmt.Errorf("pomodoro: %w", err)
	}
	clock.Notify = func(e pomodoro.Event) {
		s.events.publish("pomodoro", map[string]any{"event": e.Kind})
		s.trackSync()
		s.announcePomodoro(e)
	}
	s.pomo = clock
	cl, err := clocks.Open(filepath.Join(s.cfg.DataDir, "clocks.json"))
	if err != nil {
		return fmt.Errorf("clocks: %w", err)
	}
	cl.Notify = s.announceClock
	s.clocks = cl
	tr, err := tracker.Open(filepath.Join(s.cfg.DataDir, "track.json"), s.writeSpent)
	if err != nil {
		return fmt.Errorf("time tracking: %w", err)
	}
	tr.OnWrite = s.logTrack
	s.track = tr
	h, err := search.OpenHistory(filepath.Join(s.cfg.DataDir, "search_history.json"))
	if err != nil {
		return fmt.Errorf("search history: %w", err)
	}
	s.history = h
	return nil
}

// announcePomodoro passes a phase change on: to Neovim (GET /api/alerts)
// and through ntfy.
func (s *Server) announcePomodoro(e pomodoro.Event) {
	title, body, tags := pomodoro.Message(e)
	s.fired.add("pomodoro", title, body, time.Now())
	if !s.cfg.Ntfy.Enabled() {
		return
	}
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

// calEntry is one list item under a date of the calendar note.
type calEntry struct {
	Lnum   int    `json:"lnum"`
	Time   string `json:"time,omitempty"` // "09:00", or the start of a range
	End    string `json:"end,omitempty"`  // end of a "09:00 - 10:00" range
	Text   string `json:"text"`           // plain text, attributes removed
	HTML   string `json:"html"`           // text with links rendered
	Task   bool   `json:"task,omitempty"`
	Done   bool   `json:"done,omitempty"`
	Moved  bool   `json:"moved,omitempty"`  // [>]: carried to a later day
	Ref    string `json:"ref,omitempty"`    // no checkbox: the task it links ("rel:lnum"), whose state Done is
	Depth  int    `json:"depth,omitempty"`  // nesting under another entry
	Notify bool   `json:"notify,omitempty"` // written with @notify(…) / @n(…) (not @notify(no))
	Event  bool   `json:"event,omitempty"`  // tagged @event: fixed, planned around (the month grid's dot)
	// Resume: a block handed back after a break inside it ("12:00 Break
	// @15m" under "10:00 Study": Study again from 12:15, calbreaks.go);
	// Lnum, Text and URL are the block's, Time and End when it's back
	Resume bool `json:"resume,omitempty"`
	// a project's next open task, listed under a project block (a line
	// holding only the project's link): Rel, Lnum and Src are the task's
	Virtual bool `json:"virtual,omitempty"`
	// Feed: the calendar feed it comes from (z/feeds/<feed>.zortex,
	// app/feeds); read-only here
	Feed string `json:"feed,omitempty"`
	// Repeat: put on the day by a rule of the calendar's # Repeating section
	// (Lnum and URL are the rule's; Src its line). Copy: the line of the
	// done copy standing for it (then Lnum and Src are the copy's, and the
	// usual toggle acts on it); without one, ticking it is POST
	// /api/calendar/repeat.
	Repeat bool   `json:"repeat,omitempty"`
	Date   string `json:"date,omitempty"`
	Copy   int    `json:"copy,omitempty"`
	URL    string `json:"url"`
	Src    string `json:"src,omitempty"` // the line as written (-writable: for edits)
	Rel    string `json:"rel,omitempty"`

	textCol int // where the text starts (after the marker and a time)
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

// calendarDays: entries by date ("YYYY-MM-DD") for dates in [from, to]
// (calendarEntries), with their links rendered and the task a reference
// line stands for.
func (s *Server) calendarDays(from, to string) map[string][]calEntry {
	doc := s.calendarDoc()
	if doc == nil {
		return map[string][]calEntry{}
	}
	r := &noteRenderer{s: s, doc: doc}
	days := calendarEntries(doc, from, to)
	var all []*webProject // loaded when a day has a project block
	for date, entries := range days {
		var out []calEntry
		breaks := calResumes(entries) // before references take their task's state
		for i := range entries {
			e := &entries[i]
			line := doc.Lines[e.Lnum-1]
			e.HTML = strings.TrimSpace(r.entryHTML(line, e.Lnum, e.textCol))
			e.URL = s.noteURL(doc.Rel, e.Lnum)
			if !e.Task {
				if ref := s.referenceOf(doc, e.Lnum); ref != nil {
					e.Task, e.Done, e.Ref = true, ref.Done, fmt.Sprintf("%s:%d", ref.Rel, ref.Lnum)
				}
			}
			if s.cfg.Writable {
				e.Src, e.Rel = line, doc.Rel
			}
			out = append(out, *e)
			// a project block: the project's next open tasks under it
			if !e.Task && strings.Contains(line, "[") {
				if all == nil {
					all = s.allProjects()
				}
				for _, t := range s.projectBlock(doc, e.Lnum, all) {
					p := t.project
					col := 0
					if it := syntax.ItemOf(t.task.Line); it != nil {
						col = it.ContentCol
					}
					v := calEntry{Lnum: t.task.Lnum, Text: withoutLinks(t.task.Line, col), HTML: string(t.task.HTML), Task: true,
						Depth: e.Depth + 1, URL: t.task.URL, Virtual: true, Rel: p.Rel, Src: t.task.Line}
					if !s.cfg.Writable {
						v.Rel, v.Src = "", ""
					}
					out = append(out, v)
				}
			}
		}
		days[date] = withResumes(out, entries, breaks)
	}
	// the calendar feeds' events (z/feeds/*.zortex), among the day's own
	for _, fd := range s.feedDocs() {
		name := strings.TrimSuffix(path.Base(fd.Rel), s.cfg.Ext)
		fr := &noteRenderer{s: s, doc: fd}
		for date, entries := range calendarEntries(fd, from, to) {
			for i := range entries {
				e := &entries[i]
				e.HTML = strings.TrimSpace(fr.entryHTML(fd.Lines[e.Lnum-1], e.Lnum, e.textCol))
				e.URL = s.noteURL(fd.Rel, e.Lnum)
				e.Feed = name
				days[date] = insertByTime(days[date], *e)
			}
		}
	}
	// what the # Repeating rules put on each day, after the feeds
	if rules := edit.Rules(doc.Lines); len(rules) > 0 {
		byLnum := map[int]*edit.Rule{}
		for _, rule := range rules {
			byLnum[rule.Lnum] = rule
		}
		all := calendarEntries(doc, "", "")
		forCopies := forCopiesOf(doc, all)
		start, err1 := time.Parse("2006-01-02", from)
		stop, err2 := time.Parse("2006-01-02", to)
		for t := start; err1 == nil && err2 == nil && !t.After(stop); t = t.AddDate(0, 0, 1) {
			date := t.Format("2006-01-02")
			for _, e := range occurrences(doc, rules, all[date], forCopies, date) {
				rule := doc.Lines[e.Lnum-1]
				e.HTML = strings.TrimSpace(r.entryHTML(rule, e.Lnum, e.textCol)) + html.EscapeString(byLnum[e.Lnum].Label("", date))
				e.URL = s.noteURL(doc.Rel, e.Lnum)
				if e.Copy > 0 {
					e.Lnum, rule = e.Copy, doc.Lines[e.Copy-1]
				}
				if s.cfg.Writable {
					e.Src, e.Rel = rule, doc.Rel
				}
				days[date] = insertByTime(days[date], e)
			}
		}
	}
	return days
}

// feedDocs: the notes calendar feeds write (z/feeds/*, tagged @CalendarFeed).
func (s *Server) feedDocs() []*notes.Document {
	var out []*notes.Document
	for _, rel := range s.ix.Catalog().WithTag(strings.TrimPrefix(feeds.Marker, "@")) {
		if strings.HasPrefix(rel, "z/feeds/") {
			if d := s.ix.Doc(rel); d != nil {
				out = append(out, d)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Rel < out[j].Rel })
	return out
}

// insertByTime puts a feed's entry among a day's entries: an all-day one
// before the day's first timed top-level line, a timed one before the first
// top-level line that starts later (nested lines stay with theirs).
func insertByTime(list []calEntry, e calEntry) []calEntry {
	at := len(list)
	for i, x := range list {
		if x.Depth != 0 || x.Feed != "" && e.Time == "" && x.Time == "" {
			continue
		}
		if (e.Time == "" && x.Time != "") || (e.Time != "" && x.Time != "" && x.Time > e.Time) {
			at = i
			break
		}
	}
	list = append(list, calEntry{})
	copy(list[at+1:], list[at:])
	list[at] = e
	return list
}

type blockTask struct {
	project *webProject
	task    *webTask
}

// projectBlockTasks is how many open tasks a project block shows, as the
// plugin's ui.planner.project_tasks default.
const projectBlockTasks = 3

// projectBlock: for a calendar line holding only a link to a project (and
// attributes), with nothing nested under it, the project's next open tasks
// (its own, in note order, a group as one); else nil. As the plugin's
// services/mirrors.project_block.
func (s *Server) projectBlock(doc *notes.Document, lnum int, all []*webProject) []blockTask {
	line := doc.Lines[lnum-1]
	d := syntax.Classify(line)
	if d.Kind != syntax.KindItem || d.Item.Mark != "" || d.Item.Key != "" || d.ContentCol == nil {
		return nil
	}
	text := strings.TrimSpace(syntax.StripAttributes(line[*d.ContentCol:]))
	if len(text) < 3 || text[0] != '[' || text[len(text)-1] != ']' || strings.ContainsAny(text[1:len(text)-1], "[]") {
		return nil
	}
	own := edit.Indent(line)
	for l := lnum + 1; l <= len(doc.Lines); l++ {
		if next := doc.Lines[l-1]; strings.TrimSpace(next) != "" {
			if edit.Indent(next) > own {
				return nil
			}
			break
		}
	}
	def, err := links.Absolute(doc.Lines, lnum, text[1:len(text)-1])
	if err != nil || s.fileLike(def) {
		return nil
	}
	res, err := links.ResolveFirst(s.ix, "["+def+"]", links.Options{From: doc, Lnum: lnum})
	if err != nil || res == nil {
		return nil
	}
	var p *webProject
	if res.Whole {
		for _, x := range all {
			if x.Rel == res.Doc.Rel && x.Root {
				p = x
			}
		}
	} else if x := projectAt(all, res.Doc.Rel, res.Lnum); x != nil && x.Lnum == res.Lnum {
		p = x
	}
	if p == nil {
		return nil
	}
	var out []blockTask
	for _, t := range p.Tasks {
		if len(out) >= projectBlockTasks {
			break
		}
		if !t.Done && t.Group == "" && !strings.Contains(t.Line, "[>]") {
			out = append(out, blockTask{p, t})
		}
	}
	return out
}

// entryFlags: whether a calendar line asks for a notification itself
// (@n(…), @notify(…); every timed line notifies by default, so only a
// written one is marked) and whether it is tagged @event.
func entryFlags(spans []syntax.Span) (notify, event bool) {
	for _, sp := range spans {
		if sp.Type != "attribute" {
			continue
		}
		switch syntax.Lower(sp.Key) {
		case "n", "notify":
			notify = !strings.EqualFold(strings.TrimSpace(sp.Value), "no")
		case "event":
			event = true
		}
	}
	return notify, event
}

// entryHTML renders line[from:] like a note line, without attributes.
func (r *noteRenderer) entryHTML(line string, lnum, from int) string {
	return r.entryHTMLWithout(line, lnum, from, nil)
}

// entryHTMLWithout is entryHTML without the links that start at `hide`'s
// columns (a key result's links to the projects listed under it).
func (r *noteRenderer) entryHTMLWithout(line string, lnum, from int, hide map[int]bool) string {
	r.lnum = lnum
	spans := append([]syntax.Span(nil), r.doc.Spans(lnum)...)
	for i := range spans {
		if spans[i].Type == "attribute" || (hide[spans[i].S] && (spans[i].Type == "link" || spans[i].Type == "live_link")) {
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
//	feeds          the calendar feeds fetched (-feeds): name, title, notify,
//	               color (a notifying feed's dot on the month grid)
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
	carry := 0 // open tasks of the days before that could come to today
	if s.cfg.Writable {
		carry = s.carryCount(now.Format("2006-01-02"))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from":          from,
		"to":            to,
		"today":         now.Format("2006-01-02"),
		"days":          days,
		"notifications": view.events,
		"count":         view.pending,
		"next_event":    view.next,
		"next_time":     view.nextTime,
		"notes_enabled": s.alerts != nil,
		"writable":      s.cfg.Writable,
		"ntfy":          s.cfg.Ntfy.Enabled(),
		"carry":         carry,
		"feeds":         s.feedInfo(),
	})
}

type feedInfo struct {
	Name   string `json:"name"`
	Title  string `json:"title,omitempty"`
	Notify bool   `json:"notify,omitempty"`
	Color  string `json:"color,omitempty"`
}

// feedInfo: the feeds fetched, for the home page: a notifying feed's
// days get a dot of its color on the month grid.
func (s *Server) feedInfo() []feedInfo {
	out := []feedInfo{}
	for _, f := range s.cfg.Feeds {
		if !f.On() {
			continue
		}
		fi := feedInfo{Name: f.Name, Title: f.Title, Notify: f.Notify}
		if f.Notify {
			fi.Color = f.DotColor()
		}
		out = append(out, fi)
	}
	return out
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
}

// notificationView: the scheduled notifications as the calendar shows them.
func (s *Server) notificationView(now time.Time) notifView {
	v := notifView{events: []notifEvent{}, next: "No events"}
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

// apiSummary: GET /api/summary, for home dashboards (Homepage, Home
// Assistant, …): {generated, pending, next, text, html, pomodoro?, xp?}.
// text/html list the next notifications by day; xp is today's and the last
// seven days' area XP and the season's progress, when Neovim publishes it.
func (s *Server) apiSummary(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	v := s.notificationView(now)
	out := map[string]any{
		"generated": now.Format(time.RFC3339),
		"pending":   v.pending,
		"next":      v.next,
		"text":      v.text,
		"html":      "<pre>" + html.EscapeString(v.text) + "</pre>",
	}
	if s.pomo != nil {
		st := s.pomo.State()
		out["pomodoro"] = map[string]any{"phase": st.Phase, "running": st.Running, "remaining": st.Remaining, "today": st.Today}
	}
	if raw := s.xpSummary(); raw != nil && !s.cfg.NoXP {
		var x struct {
			Today  float64 `json:"today"`
			Week   float64 `json:"week"`
			Season *struct {
				Name     string  `json:"name"`
				Progress float64 `json:"progress"`
				Tier     string  `json:"tier"`
				SeasonXP float64 `json:"season_xp"`
			} `json:"season"`
		}
		if json.Unmarshal(raw, &x) == nil {
			xp := map[string]any{"today": x.Today, "week": x.Week}
			if x.Season != nil {
				xp["season"] = map[string]any{"name": x.Season.Name, "progress": x.Season.Progress, "tier": x.Season.Tier, "xp": x.Season.SeasonXP}
			}
			out["xp"] = xp
		}
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
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "no data directory: start zortex serve with -data"})
		return false
	}
	return true
}

// The calendar's notifications, which Neovim sends (and the server sends on
// through ntfy when they are due). X-API-Key when -api-key is set.
//
//	GET  /api/notifications?user_id=        the pending ones, soonest first
//	POST /api/notifications                 {user_id, notification}: add one
//	POST /api/notifications/sync            {user_id, notifications}: replace the pending ones
//	POST /api/notifications/clear           {user_id}: remove the pending ones
//	POST /api/notifications/test            {title?, message?}: send one through ntfy now

// notificationsRequest checks the key and the data folder and reads the
// body; user_id defaults to "default".
func (s *Server) notificationsRequest(w http.ResponseWriter, r *http.Request, v any) bool {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "bad API key"})
		return false
	}
	if !s.stateEnabled(w) {
		return false
	}
	if v == nil {
		return true
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
		return false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return false
	}
	return true
}

func userOf(id string) string {
	if id == "" {
		return "default"
	}
	return id
}

// apiNotificationsSync: POST /api/notifications/sync {user_id,
// notifications}: the pending notifications become these (unchanged ones
// keep their identity); {ok, added, updated, removed, unchanged}.
func (s *Server) apiNotificationsSync(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID        string            `json:"user_id"`
		Notifications []alerts.Incoming `json:"notifications"`
	}
	if !s.notificationsRequest(w, r, &req) {
		return
	}
	res, err := s.alerts.Sync(userOf(req.UserID), req.Notifications)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if !res.Unchanged {
		s.log.Printf("notifications: sync %s: %d added, %d updated, %d removed", userOf(req.UserID), res.Added, res.Updated, res.Removed)
	}
	s.sender.Kick()
	raw, _ := json.Marshal(res)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	out["ok"] = true
	writeJSON(w, http.StatusOK, out)
}

// apiNotificationAdd: POST /api/notifications {user_id, notification}:
// one more; {ok, id, duplicate}.
func (s *Server) apiNotificationAdd(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID       string          `json:"user_id"`
		Notification alerts.Incoming `json:"notification"`
	}
	if !s.notificationsRequest(w, r, &req) {
		return
	}
	n, added, err := s.alerts.Add(userOf(req.UserID), req.Notification)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	s.sender.Kick()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": n.ID, "duplicate": !added})
}

// apiNotificationsClear: POST /api/notifications/clear {user_id}:
// {ok, deleted}.
func (s *Server) apiNotificationsClear(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID string `json:"user_id"`
	}
	if !s.notificationsRequest(w, r, &req) {
		return
	}
	n, err := s.alerts.Clear(userOf(req.UserID))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "deleted": n})
}

// apiNotifications: GET /api/notifications?user_id= -> {count, notifications}.
func (s *Server) apiNotifications(w http.ResponseWriter, r *http.Request) {
	if !s.notificationsRequest(w, r, nil) {
		return
	}
	type out struct {
		alerts.Notification
		ScheduledDatetime string `json:"scheduled_datetime"`
	}
	list := []out{}
	for _, n := range s.alerts.Pending(userOf(r.URL.Query().Get("user_id"))) {
		list = append(list, out{n, time.Unix(n.ScheduledTime, 0).UTC().Format(time.RFC3339)})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].ScheduledTime < list[j].ScheduledTime })
	writeJSON(w, http.StatusOK, map[string]any{"count": len(list), "notifications": list})
}

// apiNotificationTest: POST /api/notifications/test {title?, message?}
// publishes through ntfy right away: {ok} or {error}.
func (s *Server) apiNotificationTest(w http.ResponseWriter, r *http.Request) {
	if !s.keyOK(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "bad API key"})
		return
	}
	if !s.jsonOrKey(r) {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]any{"error": "send JSON (Content-Type: application/json) or X-API-Key"})
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
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "ntfy is not configured (-ntfy-url, -ntfy-topic)"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if err := s.cfg.Ntfy.Publish(ctx, alerts.Message{Title: req.Title, Message: req.Message, Priority: "high", Tags: []string{"test"}}); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// apiNotFound: anything else under /api/ is a JSON 404 (not the HTML page).
func (s *Server) apiNotFound(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such endpoint: " + r.Method + " " + r.URL.Path})
}
