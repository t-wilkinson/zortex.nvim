package web

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// The note format's settings, from Neovim (lua/zortex/core/syntax_config):
// notes_dir/.z/syntax.json, {"version": 1, "label_max_words": 5}. The
// server reads it at start and whenever it changes, so a "Text:" line is a
// label here exactly when it is one in Neovim; a change reparses every note.

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
	words := syntax.DefaultMaxLabelWords
	if err == nil {
		var cfg struct {
			LabelMaxWords int `json:"label_max_words"`
		}
		if raw, rerr := os.ReadFile(s.syntaxFile()); rerr == nil && json.Unmarshal(raw, &cfg) == nil && cfg.LabelMaxWords > 0 {
			words = cfg.LabelMaxWords
		}
	}
	changed := syntax.SetMaxLabelWords(words)
	if changed {
		s.log.Printf("labels: up to %d words (.z/syntax.json)", words)
	}
	return changed
}
