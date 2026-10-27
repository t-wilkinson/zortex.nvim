package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/links"
)

// The reviews' fixes on the web (-writable), what Neovim's review keys do:
//
//	POST /api/review/note      {week, date?, label, text}  "- text" under the label of the week's
//	                           (or the day's) entry in reviews.zortex, made from its template
//	POST /api/review/focus     {week, rel, lnum}           the project in or out of the week's focus (f)
//	POST /api/review/move      {rel, lnum, expect, to}     an inbox line (and the lines under it)
//	                           to the end of a project's own lines ("rel:lnum"), without @project (m)
//	POST /api/review/tomorrow  {lnum, expect}              an open calendar task to the next day,
//	                           same time, [>] on the old line (t)
//	POST /api/review/due       {rel, lnum, expect, due}    set or move @due: YYYY-MM-DD, +N, tomorrow (d)
//	POST /api/review/area      {rel, lnum, expect, area}   @a(area) on finished work without one (A)
//	POST /api/review/finish    {date}                      end the daily review: @a(<default>) on the
//	                           finished work still without an area, and the day marked reviewed
//
// Every edit names the line it expects; when the note changed, nothing is
// written and the reply is 409.

type reviewRequest struct {
	Rel    string `json:"rel"`
	Lnum   int    `json:"lnum"`
	Expect string `json:"expect"`
	Week   string `json:"week"`
	Date   string `json:"date"`
	Label  string `json:"label"`
	Text   string `json:"text"`
	To     string `json:"to"`
	Due    string `json:"due"`
	Area   string `json:"area"`
}

var dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

func (s *Server) reviewRequest(w http.ResponseWriter, r *http.Request) (reviewRequest, bool) {
	var req reviewRequest
	if !s.writableOK(w, r) {
		return req, false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON: " + err.Error()})
		return req, false
	}
	return req, true
}

// editLine reads a note, checks line lnum is `expect`, and writes what fn
// makes of its lines.
func (s *Server) editNote(rel string, fn func(lines []string) ([]string, error)) error {
	rel, ok := cleanRel(rel)
	if !ok || rel == "" || !s.isNote(rel) || s.ix.Doc(rel) == nil {
		return fmt.Errorf("no such note: %s", rel)
	}
	f, err := readNoteFile(s.ix.Path(rel))
	if err != nil {
		return err
	}
	lines, err := fn(append([]string(nil), f.lines...))
	if err != nil {
		return err
	}
	f.lines = lines
	return f.write()
}

func expectLine(lines []string, lnum int, expect string) error {
	if lnum < 1 || lnum > len(lines) || lines[lnum-1] != expect {
		return errChanged
	}
	return nil
}

func (s *Server) reviewReply(w http.ResponseWriter, err error, out map[string]any) {
	if errors.Is(err, errChanged) {
		s.afterWrite()
		writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error() + ": reload the review"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	s.afterWrite()
	if out == nil {
		out = map[string]any{}
	}
	out["ok"] = true
	writeJSON(w, http.StatusOK, out)
}

// reviewsRel: the reviews note (made when missing).
func (s *Server) reviewsRel() (string, error) {
	if d := s.reviewsDoc(); d != nil {
		return d.Rel, nil
	}
	rel := "reviews" + s.cfg.Ext
	path := s.ix.Path(rel)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		f := &noteFile{path: path, lines: newReviewsNote(), final: true, mode: 0o664}
		if err := f.write(); err != nil {
			return "", err
		}
		s.afterWrite()
	}
	return rel, nil
}

func validWeek(week string) bool {
	_, err := parseWeek(week)
	return err == nil
}

// POST /api/review/note
func (s *Server) apiReviewNote(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	text := strings.TrimSpace(strings.ReplaceAll(req.Text, "\n", " "))
	label := strings.TrimSuffix(strings.TrimSpace(req.Label), ":")
	switch {
	case text == "":
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "empty text"})
		return
	case label == "" || strings.ContainsAny(label, "\n[]#"):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "no label"})
		return
	case req.Date != "" && !dateRe.MatchString(req.Date):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "not a date: " + req.Date})
		return
	}
	week := req.Week
	if req.Date != "" {
		t, _ := time.Parse("2006-01-02", req.Date)
		week = isoWeek(t)
	}
	if !validWeek(week) {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "not a week: " + week})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	rel, err := s.reviewsRel()
	if err != nil {
		s.reviewReply(w, err, nil)
		return
	}
	at := 0
	err = s.editNote(rel, func(lines []string) ([]string, error) {
		if req.Date != "" {
			lines, _ = ensureDay(lines, req.Date, week)
		} else {
			lines, _ = ensureWeek(lines, week)
		}
		from, to, ok := entryRange(lines, week, req.Date)
		if !ok {
			return nil, errors.New("no entry for " + week + " " + req.Date)
		}
		lines, at = addUnderLabel(lines, from, to, label, text)
		return lines, nil
	})
	s.reviewReply(w, err, map[string]any{"rel": rel, "lnum": at, "url": s.noteURL(rel, at)})
}

// bracketLink: a link as written, "[P/#1 Programming/#1.4 - zortex]", as
// Neovim's reviews and planner write them (services/planner shown()).
func bracketLink(link string) string {
	return "[" + strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(link), "["), "]") + "]"
}

func (s *Server) projectAtLine(all []*webProject, rel string, lnum int) *webProject {
	for _, p := range all {
		if p.Rel == rel && p.Lnum == lnum && !p.Root {
			return p
		}
	}
	return nil
}

// POST /api/review/focus
func (s *Server) apiReviewFocus(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	if !validWeek(req.Week) {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "not a week: " + req.Week})
		return
	}
	all := s.allProjects()
	p := s.projectAtLine(all, req.Rel, req.Lnum)
	if p == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no project there"})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	rel, err := s.reviewsRel()
	if err != nil {
		s.reviewReply(w, err, nil)
		return
	}
	added := false
	doc := s.ix.Doc(rel)
	err = s.editNote(rel, func(lines []string) ([]string, error) {
		lines, _ = ensureWeek(lines, req.Week)
		weeks, _ := reviewEntries(lines)
		e := weeks[req.Week]
		if e.FocusLnum > 0 {
			for l := e.FocusFrom; l <= e.FocusTo; l++ {
				for _, sp := range links.LinksOn(lines[l-1]) {
					res, err := links.ResolveFirst(s.ix, "["+sp.Definition+"]", links.Options{From: doc, Lnum: l})
					if err != nil || res == nil {
						continue
					}
					if list := projectsFor(all, res.Doc.Rel, res.Lnum, res.Doc); len(list) > 0 && list[0] == p {
						return append(lines[:l-1], lines[l:]...), nil
					}
					break
				}
			}
		}
		added = true
		item := "- " + bracketLink(p.Link)
		if e.FocusLnum == 0 {
			out := append([]string(nil), lines[:e.Lnum]...)
			out = append(out, "Focus:", item)
			return append(out, lines[e.Lnum:]...), nil
		}
		m := reviewFocusRe.FindStringSubmatch(lines[e.FocusLnum-1])
		out := append([]string(nil), lines[:e.FocusTo]...)
		out = append(out, m[1]+item)
		return append(out, lines[e.FocusTo:]...), nil
	})
	s.reviewReply(w, err, map[string]any{"added": added, "project": p.Name})
}

// POST /api/review/move
func (s *Server) apiReviewMove(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	i := strings.LastIndex(req.To, ":")
	tlnum := 0
	if i >= 0 {
		tlnum, _ = strconv.Atoi(req.To[i+1:])
	}
	if tlnum < 1 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "no project picked"})
		return
	}
	all := s.allProjects()
	p := s.projectAtLine(all, req.To[:i], tlnum)
	if p == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no project there"})
		return
	}
	src, ok := cleanRel(req.Rel)
	if !ok || s.ix.Doc(src) == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no such note: " + req.Rel})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	f, err := readNoteFile(s.ix.Path(src))
	if err == nil {
		err = expectLine(f.lines, req.Lnum, req.Expect)
	}
	if err != nil {
		s.reviewReply(w, err, nil)
		return
	}
	// the line and the lines indented under it, without @project, lined up
	// at the left like a project's tasks
	end := blockEnd(f.lines, req.Lnum)
	block := append([]string(nil), f.lines[req.Lnum-1:end]...)
	block[0] = edit.RemoveAttribute(block[0], "project")
	_, pad := indentWidth(block[0])
	for k, l := range block {
		block[k] = strings.TrimPrefix(l, pad)
	}
	// where: after the last non-blank line of the project's own lines
	target := p.Lnum
	insert := func(lines []string) []string {
		at := target
		own := p.OwnEnd
		if own > len(lines) {
			own = len(lines)
		}
		for l := own; l > target; l-- {
			if strings.TrimSpace(lines[l-1]) != "" {
				at = l
				break
			}
		}
		out := append([]string(nil), lines[:at]...)
		out = append(out, block...)
		return append(out, lines[at:]...)
	}
	if p.Rel == src {
		if req.Lnum <= p.OwnEnd && end >= p.Lnum {
			s.reviewReply(w, errors.New("it is already there"), nil)
			return
		}
		lines := append(append([]string(nil), f.lines[:req.Lnum-1]...), f.lines[end:]...)
		if req.Lnum < p.Lnum {
			n := end - req.Lnum + 1
			target -= n
			p.OwnEnd -= n
		}
		f.lines = insert(lines)
		err = f.write()
	} else {
		err = s.editNote(p.Rel, func(lines []string) ([]string, error) { return insert(lines), nil })
		if err == nil {
			f.lines = append(f.lines[:req.Lnum-1], f.lines[end:]...)
			err = f.write()
		}
	}
	s.reviewReply(w, err, map[string]any{"project": p.Name, "url": s.projectURL(p)})
}

// POST /api/review/tomorrow
func (s *Server) apiReviewTomorrow(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	cal := s.calendarDoc()
	if cal == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no calendar note"})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	day := ""
	err := s.editNote(cal.Rel, func(lines []string) ([]string, error) {
		if err := expectLine(lines, req.Lnum, req.Expect); err != nil {
			return nil, err
		}
		out, next, _, err := edit.ToNextDay(lines, req.Lnum, s.newID)
		day = next
		return out, err
	})
	s.reviewReply(w, err, map[string]any{"date": day})
}

// parseDay: "2026-10-21", "+3" (days from today), "tomorrow", "today".
func parseDay(text string, now time.Time) (string, bool) {
	text = strings.TrimSpace(strings.ToLower(text))
	switch text {
	case "", "tomorrow":
		return now.AddDate(0, 0, 1).Format("2006-01-02"), true
	case "today":
		return now.Format("2006-01-02"), true
	}
	if strings.HasPrefix(text, "+") {
		if n, err := strconv.Atoi(text[1:]); err == nil && n >= 0 && n < 3650 {
			return now.AddDate(0, 0, n).Format("2006-01-02"), true
		}
		return "", false
	}
	if t, err := time.Parse("2006-01-02", text); err == nil {
		return t.Format("2006-01-02"), true
	}
	return "", false
}

// POST /api/review/due
func (s *Server) apiReviewDue(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	day, ok := parseDay(req.Due, time.Now())
	if !ok {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "not a date: " + req.Due + " (YYYY-MM-DD, +N, tomorrow)"})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	err := s.editNote(req.Rel, func(lines []string) ([]string, error) {
		if err := expectLine(lines, req.Lnum, req.Expect); err != nil {
			return nil, err
		}
		lines[req.Lnum-1] = edit.UpdateAttribute(lines[req.Lnum-1], "due", day)
		return lines, nil
	})
	s.reviewReply(w, err, map[string]any{"due": day})
}

// withArea: the line with @a(value) as its only area attribute.
func withArea(line, value string) string {
	line = edit.RemoveAttribute(line, "area")
	line = edit.RemoveAttribute(line, "a")
	return edit.UpdateAttribute(line, "a", value)
}

// POST /api/review/area
func (s *Server) apiReviewArea(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	value := strings.TrimSpace(req.Area)
	_, _, byLine, d := s.areaTree()
	if value == "" || strings.ContainsAny(value, "()") || s.resolveArea(value, byLine, d) == nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "no such area: " + value})
		return
	}
	s.editMu.Lock()
	defer s.editMu.Unlock()
	err := s.editNote(req.Rel, func(lines []string) ([]string, error) {
		if err := expectLine(lines, req.Lnum, req.Expect); err != nil {
			return nil, err
		}
		lines[req.Lnum-1] = withArea(lines[req.Lnum-1], value)
		return lines, nil
	})
	s.reviewReply(w, err, map[string]any{"area": value})
}

// POST /api/review/finish
func (s *Server) apiReviewFinish(w http.ResponseWriter, r *http.Request) {
	req, ok := s.reviewRequest(w, r)
	if !ok {
		return
	}
	date := req.Date
	if date == "" || !dateRe.MatchString(date) {
		date = time.Now().Format("2006-01-02")
	}
	st := s.readReviewState()
	from := dayWindow(st, date)
	areaFrom := areaWindow(st, date, from)
	all := s.allProjects()
	items := s.unassigned(all, areaFrom, date)
	value := s.defaultAreaValue()
	_, _, byLine, d := s.areaTree()
	stamped := 0
	s.editMu.Lock()
	defer s.editMu.Unlock()
	var err error
	if value != "" && s.resolveArea(value, byLine, d) != nil && len(items) > 0 {
		byRel := map[string][]unassignedItem{}
		for _, it := range items {
			byRel[it.Rel] = append(byRel[it.Rel], it)
		}
		for rel, list := range byRel {
			e := s.editNote(rel, func(lines []string) ([]string, error) {
				for _, it := range list {
					if it.Lnum >= 1 && it.Lnum <= len(lines) && lines[it.Lnum-1] == it.Src {
						lines[it.Lnum-1] = withArea(lines[it.Lnum-1], value)
						stamped++
					}
				}
				return lines, nil
			})
			if e != nil && err == nil {
				err = e
			}
		}
	}
	if err == nil {
		err = s.writeReviewState(reviewState{LastDay: date, From: from})
	}
	s.reviewReply(w, err, map[string]any{"stamped": stamped, "area": value, "date": date})
}
