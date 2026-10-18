package web

import (
	"net/http"
	"path"
	"sort"
	"strings"

	"github.com/t-wilkinson/zortex.nvim/app/notes"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Structure coverage. The Structure note (@@Structure, usually
// structure.zortex) links every note into one whole, helped by any note
// tagged @Structure and by the "# Structure" section of any note (a hub
// listing its own sub-notes; the rest of that note is ordinary content).
// A note that none of them links to is "unlinked": it isn't part of the
// structure yet. Archived notes are left out on both sides.

const structureName = "Structure"

// structureInfo is computed with each snapshot.
type structureInfo struct {
	Sources  []string          // notes that are or hold structure
	Roots    []string          // the Structure note(s) themselves
	Ranges   map[string][]span // source -> its structure lines (whole note, or # Structure sections)
	Linked   int               // notes the sources link to
	Unlinked []string          // notes nothing in the structure links to, by folder then name
	Total    int               // notes considered
}

// span is a range of lines, both ends included.
type span struct{ First, Last int }

// inStructure reports whether line lnum of rel lists structure.
func (info structureInfo) inStructure(rel string, lnum int) bool {
	for _, r := range info.Ranges[rel] {
		if lnum >= r.First && lnum <= r.Last {
			return true
		}
	}
	return false
}

// structureSections are the top-level "# Structure" sections of a note.
func structureSections(doc *notes.Document) []span {
	var out []span
	doc.Tree.Walk(func(n *notes.Node) {
		if n.Type == syntax.KindHeading && n.Level == 1 && strings.EqualFold(strings.TrimSpace(n.Text), structureName) {
			out = append(out, span{n.Start, n.End})
		}
	})
	return out
}

func (s *Server) buildStructure(snap *snapshot) structureInfo {
	cat := s.ix.Catalog()
	seen := map[string]bool{}
	root := map[string]bool{} // the Structure note itself: needs no link
	var info structureInfo
	info.Ranges = map[string][]span{}
	add := func(rel string, isRoot bool, ranges []span) {
		doc := s.ix.Doc(rel)
		if cat.IsArchived(rel) || doc == nil {
			return
		}
		if isRoot && !root[rel] {
			root[rel] = true
			info.Roots = append(info.Roots, rel)
		}
		if !seen[rel] {
			seen[rel] = true
			info.Sources = append(info.Sources, rel)
		}
		if ranges == nil {
			ranges = []span{{1, len(doc.Lines)}}
		}
		if _, done := info.Ranges[rel]; !done || ranges[0].First == 1 && ranges[0].Last == len(doc.Lines) {
			info.Ranges[rel] = ranges
		}
	}
	add("structure"+s.cfg.Ext, true, nil)
	for _, rel := range cat.WithName(structureName) {
		add(rel, true, nil)
	}
	for _, rel := range cat.WithTag(structureName) {
		add(rel, false, nil) // a @Structure note still needs a link into the structure
	}
	for _, rel := range cat.Files(false) {
		if _, done := info.Ranges[rel]; done || !s.isNote(rel) {
			continue
		}
		if doc := s.ix.Doc(rel); doc != nil {
			if secs := structureSections(doc); len(secs) > 0 {
				add(rel, false, secs) // so does a note with a # Structure section
			}
		}
	}
	sort.Strings(info.Sources)
	if len(info.Sources) == 0 {
		return info
	}
	linked := map[string]bool{}
	for target, list := range snap.backlinks {
		for _, b := range list {
			if b.FromNote && info.inStructure(b.From, b.Lnum) {
				linked[target] = true
				break
			}
		}
	}
	for _, rel := range cat.Files(false) {
		if !s.isNote(rel) || root[rel] {
			continue
		}
		info.Total++
		if linked[rel] {
			info.Linked++
		} else {
			info.Unlinked = append(info.Unlinked, rel)
		}
	}
	sort.Slice(info.Unlinked, func(i, j int) bool {
		a, b := info.Unlinked[i], info.Unlinked[j]
		da, db := path.Dir(a), path.Dir(b)
		if da != db {
			if da == "." || db == "." {
				return da == "."
			}
			return da < db
		}
		return strings.ToLower(a) < strings.ToLower(b)
	})
	return info
}

// structureSide is the sidebar data for a Structure note's page, or nil
// when rel isn't one.
func (s *Server) structureSide(rel string) map[string]any {
	info := s.current().structure
	isRoot := false
	for _, r := range info.Roots {
		isRoot = isRoot || r == rel
	}
	if !isRoot {
		return nil
	}
	type row struct{ Rel, Title, Dir string }
	var rows []row
	for _, u := range info.Unlinked {
		d := path.Dir(u)
		if d == "." {
			d = ""
		}
		rows = append(rows, row{u, s.noteTitle(u), d})
	}
	return map[string]any{"Rows": rows, "Unlinked": len(info.Unlinked), "Total": info.Total, "Sources": info.Sources}
}

// apiStructure: GET /api/structure -> {sources, linked, total, unlinked: [{rel, title, url}]}
func (s *Server) apiStructure(w http.ResponseWriter, r *http.Request) {
	info := s.current().structure
	type out struct {
		Rel   string `json:"rel"`
		Title string `json:"title"`
		URL   string `json:"url"`
	}
	list := []out{}
	for _, rel := range info.Unlinked {
		list = append(list, out{rel, s.noteTitle(rel), s.noteURL(rel, 0)})
	}
	sources := info.Sources
	if sources == nil {
		sources = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"sources": sources, "linked": info.Linked, "total": info.Total, "unlinked": list})
}
