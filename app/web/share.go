package web

// GET /calendar.ics: the calendar note's lines tagged @share, as an
// iCalendar feed other calendars subscribe to (Cozi's "Connected
// Calendars", Google, Apple), so the people you plan with see your blocks.
//
//	@share    on a calendar line (a timed one, or a day's note or task)
//
// Only @share lines leave: your other plans, your notes and the links in
// shared lines (shown as their text) stay private. A calendar app can't
// log in, so with -share-token-file the feed is also served without the
// login to ?token=<token> (behind a proxy with its own login, let
// /calendar.ics through to the app). The window is 30 days back to 180
// ahead; a timed line without an end lasts 30 minutes, an untimed one is an
// all-day event.

import (
	"crypto/sha1"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/ical"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// shareTokenOK: the request carries the share token (constant-time).
func (s *Server) shareTokenOK(r *http.Request) bool {
	tok := r.URL.Query().Get("token")
	return s.cfg.ShareToken != "" && tok != "" &&
		subtle.ConstantTimeCompare([]byte(tok), []byte(s.cfg.ShareToken)) == 1
}

// sharePublic: /calendar.ics with the right token skips the login.
func (s *Server) sharePublic(path string, r *http.Request) bool {
	return path == "/calendar.ics" && s.shareTokenOK(r)
}

// shared: the @share entries of the calendar in [from, to] as events.
func (s *Server) shared(from, to time.Time, site string) []ical.Out {
	doc := s.calendarDoc()
	if doc == nil {
		return nil
	}
	loc := time.Local
	days := calendarEntries(doc, from.Format("2006-01-02"), to.Format("2006-01-02"))
	var dates []string
	for d := range days {
		dates = append(dates, d)
	}
	sort.Strings(dates)
	var out []ical.Out
	for _, date := range dates {
		day, err := time.ParseInLocation("2006-01-02", date, loc)
		if err != nil {
			continue
		}
		for _, e := range days[date] {
			line := doc.Lines[e.Lnum-1]
			if !sharedLine(doc.Spans(e.Lnum)) {
				continue
			}
			summary := compactText(line, e.textCol)
			if summary == "" {
				continue
			}
			ev := ical.Out{Summary: summary}
			if id := edit.ID(line); id != "" {
				ev.UID = id + "-" + date + "@zortex"
			} else {
				h := sha1.Sum([]byte(date + "\n" + strings.TrimSpace(line)))
				ev.UID = hex.EncodeToString(h[:8]) + "@zortex"
			}
			if _, m, ok := clock(e.Time); ok {
				ev.Start = day.Add(time.Duration(m) * time.Minute)
				ev.End = ev.Start.Add(30 * time.Minute)
				if _, me, ok := clock(e.End); ok {
					end := day.Add(time.Duration(me) * time.Minute)
					if !end.After(ev.Start) {
						end = end.AddDate(0, 0, 1) // past midnight
					}
					ev.End = end
				}
			} else {
				ev.AllDay, ev.Start, ev.End = true, day, day.AddDate(0, 0, 1)
			}
			if site != "" {
				ev.URL = site + s.noteURL(doc.Rel, e.Lnum)
			}
			out = append(out, ev)
		}
	}
	return out
}

// sharedLine: the line carries @share (or @share(…), for a later
// per-person feed).
func sharedLine(spans []syntax.Span) bool {
	for _, sp := range spans {
		if sp.Type == "attribute" && strings.EqualFold(sp.Key, "share") {
			return true
		}
	}
	return false
}

func (s *Server) handleShareICS(w http.ResponseWriter, r *http.Request) {
	// with a share token and no login of the app's own, the token is the
	// only way in (a proxy in front lets this path through)
	if s.cfg.ShareToken != "" && len(s.cfg.Accounts) == 0 && !s.shareTokenOK(r) {
		http.NotFound(w, r)
		return
	}
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	site := scheme + "://" + r.Host
	events := s.shared(today.AddDate(0, 0, -30), today.AddDate(0, 0, 180), site)
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_ = ical.Write(w, s.cfg.Title, events, now)
}
