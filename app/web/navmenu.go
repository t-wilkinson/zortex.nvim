package web

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The top bar's Files menu (on hover, or its ▾ on a phone): the folders of
// z/ (books, feeds, archives, …) in one column, the notes at the top of the
// folder with a name of their own (not a generated 2026-10-15.042) in the
// other. Built with each snapshot, so a page costs nothing for it.

type navNote struct {
	Rel, Title string
}

type navMenu struct {
	Folders []string // "z/books", …
	Notes   []navNote
	More    int // notes left out (the menu shows navMenuNotes)
}

const navMenuNotes = 40

func (s *Server) buildNavMenu(all []string) navMenu {
	var m navMenu
	if des, err := os.ReadDir(filepath.Join(s.cfg.Root, "z")); err == nil {
		for _, de := range des {
			name := de.Name()
			if strings.HasPrefix(name, ".") || isSyncArtifact(name) {
				continue
			}
			if st, err := os.Stat(filepath.Join(s.cfg.Root, "z", name)); err == nil && st.IsDir() {
				m.Folders = append(m.Folders, "z/"+name)
			}
		}
	}
	for _, rel := range all {
		if strings.Contains(rel, "/") || generatedName(rel, s.cfg.Ext) || s.ix.IsArchived(rel) {
			continue
		}
		title := strings.TrimSuffix(rel, s.cfg.Ext)
		if d := s.ix.Doc(rel); d != nil {
			title = d.Title()
		}
		m.Notes = append(m.Notes, navNote{Rel: rel, Title: title})
	}
	sort.Strings(m.Folders)
	sort.SliceStable(m.Notes, func(i, j int) bool { return strings.ToLower(m.Notes[i].Title) < strings.ToLower(m.Notes[j].Title) })
	if len(m.Notes) > navMenuNotes {
		m.More = len(m.Notes) - navMenuNotes
		m.Notes = m.Notes[:navMenuNotes]
	}
	return m
}

// zFolders: the folders of z/, as /f/ lists them under z/ at the top level.
func (s *Server) zFolders() []entry {
	var out []entry
	for _, rel := range s.current().nav.Folders {
		st, err := os.Stat(filepath.Join(s.cfg.Root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		out = append(out, entry{Name: rel, Rel: rel, Dir: true, Sub: true, ModTime: st.ModTime(), Title: rel, Unlinked: s.current().unlinked[rel]})
	}
	return out
}
