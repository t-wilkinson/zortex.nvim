package web

import (
	"net/http"
	"path"
	"sort"
	"strings"
)

// Structure coverage. The Structure note (@@Structure, usually
// structure.zortex) links every note into one whole, helped by any note
// tagged @Structure. A note that none of them links to is "unlinked": it
// isn't part of the structure yet. Archived notes are left out on both sides.

const structureName = "Structure"

// structureInfo is computed with each snapshot.
type structureInfo struct {
	Sources  []string // the Structure note and @Structure notes
	Roots    []string // the Structure note(s) themselves
	Linked   int      // notes the sources link to
	Unlinked []string // notes nothing in the structure links to, by folder then name
	Total    int      // notes considered
}

func (s *Server) buildStructure(snap *snapshot) structureInfo {
	cat := s.ix.Catalog()
	seen := map[string]bool{}
	root := map[string]bool{} // the Structure note itself: needs no link
	var info structureInfo
	add := func(rel string, isRoot bool) {
		if cat.IsArchived(rel) || s.ix.Doc(rel) == nil {
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
	}
	add("structure"+s.cfg.Ext, true)
	for _, rel := range cat.WithName(structureName) {
		add(rel, true)
	}
	for _, rel := range cat.WithTag(structureName) {
		add(rel, false) // a @Structure note still needs a link into the structure
	}
	sort.Strings(info.Sources)
	if len(info.Sources) == 0 {
		return info
	}
	linked := map[string]bool{}
	for target, list := range snap.backlinks {
		for _, b := range list {
			if b.FromNote && seen[b.From] {
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

// handleStructure: the Structure note, rendered like any note (its sidebar
// lists the notes it doesn't reach), or how to create one.
func (s *Server) handleStructure(w http.ResponseWriter, r *http.Request) {
	info := s.current().structure
	if len(info.Roots) > 0 {
		s.renderNotePage(w, r, info.Roots[0], "structure")
		return
	}
	s.render(w, r, "structure", http.StatusOK, map[string]any{"Title": "Structure"})
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
