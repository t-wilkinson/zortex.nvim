package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The note format's settings, from Neovim (lua/zortex/core/syntax_config):
// notes_dir/.z/syntax.json, {"version": 1, "label_max_words": 5,
// "label_pattern": "^%u%u+$", "group_days": false, "documents": ["docs"]}.
// The server reads it at start and whenever it changes, so a "Key:" line
// reads as a label here exactly when it does in Neovim (a change reparses
// every note; the pattern is Lua's, translated), the days it adds to the
// calendar make month headings only when Neovim's do, and the Markdown and
// HTML documents are in the same folders (default z/markdown and z/html).

func (s *Server) syntaxFile() string { return filepath.Join(s.cfg.Root, ".z", "syntax.json") }

// checkSyntaxFile applies .z/syntax.json when it changed since the last
// look; reports whether the grammar changed (the notes need reparsing).
func (s *Server) checkSyntaxFile() bool {
	var mod time.Time
	st, err := os.Stat(s.syntaxFile())
	if err == nil {
		mod = st.ModTime()
	}
	s.syntaxMu.Lock()
	defer s.syntaxMu.Unlock()
	if s.syntaxChecked && mod.Equal(s.syntaxSeen) {
		return false
	}
	s.syntaxSeen, s.syntaxChecked = mod, true
	words, pattern, group := syntax.DefaultMaxLabelWords, "", true
	var documents []string // nil: the default folders
	if err == nil {
		var cfg struct {
			LabelMaxWords *int      `json:"label_max_words"`
			LabelPattern  string    `json:"label_pattern"`
			GroupDays     *bool     `json:"group_days"`
			Documents     *[]string `json:"documents"`
		}
		if raw, rerr := os.ReadFile(s.syntaxFile()); rerr == nil && json.Unmarshal(raw, &cfg) == nil {
			if cfg.LabelMaxWords != nil && *cfg.LabelMaxWords >= 0 {
				words = *cfg.LabelMaxWords
			}
			pattern = cfg.LabelPattern
			group = cfg.GroupDays == nil || *cfg.GroupDays
			if cfg.Documents != nil {
				documents = append([]string{}, *cfg.Documents...)
			}
		}
	}
	edit.SetGroupDays(group)
	changed, perr := syntax.SetLabelRule(words, pattern)
	if perr != nil {
		s.log.Printf("labels: label_pattern %q: %v (.z/syntax.json)", pattern, perr)
	}
	if changed {
		s.log.Printf("labels: up to %d words, pattern %q (.z/syntax.json)", words, syntax.LabelPattern())
	}
	if s.ix.SetDocumentFolders(documents) {
		s.log.Printf("documents: %v (.z/syntax.json)", s.ix.DocumentFolders())
		changed = true
	}
	return changed
}
