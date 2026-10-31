package web

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Hover cards (static/hover.js): what a link to a note (or a Markdown or
// HTML document, notes/documents.go) shows before you follow it. GET /api/hover?rel=&lnum= -> {title, rel, section, tags,
// lines, backlinks}. Images and external links need no call: the card shows
// the image itself, or the domain and URL (the server fetches nothing).

const hoverLines = 4

type hoverCard struct {
	Title     string   `json:"title"`
	Rel       string   `json:"rel"`
	Section   string   `json:"section,omitempty"` // the heading the link lands on
	Tags      []string `json:"tags"`
	Lines     []string `json:"lines"` // its first lines, as text
	Backlinks int      `json:"backlinks"`
}

func (s *Server) apiHover(w http.ResponseWriter, r *http.Request) {
	rel := r.URL.Query().Get("rel")
	lnum, _ := strconv.Atoi(r.URL.Query().Get("lnum"))
	card, ok := hoverCard{}, s.isNote(rel) || s.ix.DocumentKind(rel) != ""
	if ok {
		card, ok = s.hoverCardOf(rel, lnum, hoverLines)
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no note " + rel})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, card)
}

// hoverCardOf: a note's card (at lnum's section when a heading starts
// there), with up to `lines` of its first lines; ok is false for no note.
func (s *Server) hoverCardOf(rel string, lnum, lines int) (hoverCard, bool) {
	d := s.ix.Doc(rel)
	if d == nil {
		return hoverCard{}, false
	}
	h := d.Header()
	card := hoverCard{Title: d.Title(), Rel: rel, Tags: append([]string{}, h.Tags...), Lines: []string{}}
	first, last := h.LastLnum+1, len(d.Lines)
	if s.ix.DocumentKind(rel) == "html" {
		first += 2 // past "From [the page]"
	}
	if lnum > 1 && lnum <= len(d.Lines) {
		first = lnum
		if n := d.NodeAt(lnum); n != nil && !n.IsRoot() && n.Start == lnum {
			card.Section = n.Breadcrumb(" › ")
			first, last = lnum+1, n.End
		}
	}
	for l := first; l <= last && len(card.Lines) < lines; l++ {
		if l < 1 || d.InCode(l) {
			continue
		}
		line := d.Lines[l-1]
		if strings.TrimSpace(line) == "" {
			continue
		}
		col := 0
		if c := syntax.Classify(line); c.ContentCol != nil {
			col = *c.ContentCol
		}
		if t := compactText(line, col); t != "" {
			if len(t) > 140 {
				t = t[:137] + "…"
			}
			card.Lines = append(card.Lines, t)
		}
	}
	for _, b := range s.current().backlinks[rel] {
		if card.Section == "" || (b.ToLnum >= first-1 && b.ToLnum <= last) {
			card.Backlinks++
		}
	}
	return card, true
}
