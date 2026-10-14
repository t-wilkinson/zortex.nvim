package web

import (
	"html/template"
	"net/http"
	"strconv"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// A note as a slide deck: /n/<rel>?view=slides.
//
// Headings at the slide level start a slide; headings above it start a
// section slide; the header and whatever comes before the first of them is
// the title slide. The level is @slides(n) in the header, or else the second
// heading level the note uses (# and ##: ## are slides and # sections), or
// the only one. Deeper headings stay inside their slide.
//
// A "Notes:" label (or **Notes:**) is its slide's speaker notes: hidden on
// the slide, shown in the presenter window. @step on a line reveals it (and
// the lines nested under it) on its own click; @steps on a slide's heading
// does that for each of its top-level items.

type slide struct {
	Kind  string // "title", "section" or "slide"
	Lnum  int    // first line
	End   int    // last line
	Steps int    // reveal steps (0: all at once)
	Body  template.HTML
	Notes template.HTML
}

// slideLevel is the heading level that starts a slide (0: no headings, the
// whole note is one slide).
func slideLevel(doc *notes.Document, ast *syntax.AST) int {
	for _, t := range doc.Header().Tags {
		if k, v, ok := strings.Cut(t, "("); ok && strings.EqualFold(k, "slides") {
			if n, err := strconv.Atoi(strings.TrimSuffix(strings.TrimSpace(v), ")")); err == nil && n >= 1 && n <= 6 {
				return n
			}
		}
	}
	var used [7]bool
	for i, d := range ast.Lines {
		if i+1 > ast.Header.LastLnum && d.Kind == syntax.KindHeading && d.Heading >= 1 && d.Heading <= 6 {
			used[d.Heading] = true
		}
	}
	first := 0
	for l := 1; l <= 6; l++ {
		if !used[l] {
			continue
		}
		if first != 0 {
			return l
		}
		first = l
	}
	return first
}

// splitSlides cuts a note into slides (line ranges only).
func splitSlides(doc *notes.Document, ast *syntax.AST) []slide {
	level := slideLevel(doc, ast)
	n := len(doc.Lines)
	out := []slide{{Kind: "title", Lnum: 1}}
	for lnum := ast.Header.LastLnum + 1; lnum <= n; lnum++ {
		d := ast.Lines[lnum-1]
		if d.Kind != syntax.KindHeading || level == 0 || d.Heading > level {
			continue
		}
		out[len(out)-1].End = lnum - 1
		kind := "slide"
		if d.Heading < level {
			kind = "section"
		}
		out = append(out, slide{Kind: kind, Lnum: lnum})
	}
	out[len(out)-1].End = n
	return out
}

// renderSlides renders every slide's body and notes.
func (s *Server) renderSlides(doc *notes.Document) []slide {
	ast := doc.Parse()
	slides := splitSlides(doc, ast)
	for i := range slides {
		sl := &slides[i]
		r := &noteRenderer{s: s, doc: doc, ast: ast, slides: true}
		notesAt := speakerNotes(doc, ast, sl.Lnum, sl.End)
		r.steps, sl.Steps = slideSteps(doc, ast, sl.Lnum, sl.End)

		first := sl.Lnum
		switch sl.Kind {
		case "title":
			r.w(`<h1 class="deck-title">`, esc(doc.Title()), `</h1>`)
		default:
			r.w(`<header class="slide-head">`)
			r.renderRange(sl.Lnum, sl.Lnum)
			r.w(`</header>`)
			first++
		}
		r.w(`<div class="slide-body">`)
		for lnum := first; lnum <= sl.End; {
			if end, ok := notesAt[lnum]; ok {
				lnum = end + 1
				continue
			}
			stop := lnum
			for stop < sl.End {
				if _, ok := notesAt[stop+1]; ok {
					break
				}
				stop++
			}
			r.renderRange(lnum, stop)
			lnum = stop + 1
		}
		r.w(`</div>`)
		sl.Body = template.HTML(r.b.String())

		if len(notesAt) > 0 {
			nr := &noteRenderer{s: s, doc: doc, ast: ast}
			for lnum := sl.Lnum; lnum <= sl.End; lnum++ {
				if end, ok := notesAt[lnum]; ok {
					nr.renderRange(lnum+1, end)
				}
			}
			sl.Notes = template.HTML(nr.b.String())
		}
	}
	return slides
}

// speakerNotes finds the Notes: sections between first and last: their
// label line -> last line.
func speakerNotes(doc *notes.Document, ast *syntax.AST, first, last int) map[int]int {
	out := map[int]int{}
	for lnum := first; lnum <= last; lnum++ {
		k := ast.Lines[lnum-1].Kind
		if k != syntax.KindLabel && k != syntax.KindBoldHeading {
			continue
		}
		node := doc.NodeStartingAt(lnum)
		if node == nil || !strings.EqualFold(strings.TrimSpace(node.Text), "notes") {
			continue
		}
		end := min(node.End, last)
		out[lnum] = end
		lnum = end
	}
	return out
}

// slideSteps numbers the lines revealed one click at a time: lnum -> step.
func slideSteps(doc *notes.Document, ast *syntax.AST, first, last int) (map[int]int, int) {
	all := first <= len(ast.Lines) && ast.Lines[first-1].Kind == syntax.KindHeading && hasAttr(doc, first, "steps")
	top := -1 // the indent of the slide's top-level items, for @steps
	if all {
		for lnum := first + 1; lnum <= last; lnum++ {
			if d := ast.Lines[lnum-1]; d.Kind == syntax.KindItem && (top < 0 || d.Indent < top) {
				top = d.Indent
			}
		}
	}
	steps := map[int]int{}
	n := 0
	owner := -1 // indent of the line whose step nested lines share; -1: none
	for lnum := first + 1; lnum <= last; lnum++ {
		d := ast.Lines[lnum-1]
		if d.Kind == syntax.KindBlank {
			continue
		}
		nested := owner >= 0 && d.Indent > owner && d.Kind != syntax.KindHeading
		switch {
		case hasAttr(doc, lnum, "step") || (all && d.Kind == syntax.KindItem && d.Indent == top):
			n++
			steps[lnum] = n
			if !nested {
				owner = d.Indent
			}
		case nested:
			steps[lnum] = n
		default:
			owner = -1
		}
	}
	return steps, n
}

// hasAttr reports whether line lnum has the attribute @key.
func hasAttr(doc *notes.Document, lnum int, key string) bool {
	found := false
	syntax.Walk(doc.Spans(lnum), func(sp *syntax.Span) {
		if sp.Type == "attribute" && strings.EqualFold(sp.Key, key) {
			found = true
		}
	})
	return found
}

func (s *Server) handleSlides(w http.ResponseWriter, r *http.Request, rel string) {
	doc := s.ix.Doc(rel)
	if doc == nil {
		s.notFound(w, r, "No such note: "+rel)
		return
	}
	s.render(w, r, "slides", http.StatusOK, map[string]any{
		"Title":  doc.Title(),
		"Rel":    rel,
		"Note":   s.noteURL(rel, 0),
		"Mod":    doc.ModTime.UnixNano(),
		"Slides": s.renderSlides(doc),
	})
}
