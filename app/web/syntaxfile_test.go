package web

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// Neovim's syntax.label_max_words reaches the server through .z/syntax.json:
// a four-word "Text:" line becomes a label, and links to it resolve.
func TestSyntaxFileLabelWords(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	defer syntax.SetMaxLabelWords(syntax.DefaultMaxLabelWords)
	note := "@@Doctor\n\nQuestions for the doctor:\n- the knee\n"
	os.WriteFile(filepath.Join(dir, "doctor.zortex"), []byte(note), 0o644)
	os.WriteFile(filepath.Join(dir, "links2.zortex"), []byte("@@L2\n\n- [Doctor/:Questions for the doctor]\n"), 0o644)
	s.Refresh()
	if d := s.ix.Doc("doctor.zortex"); d.NodeAt(3) != nil && !d.NodeAt(3).IsRoot() && d.NodeAt(3).Type == syntax.KindLabel {
		t.Fatal("four words: not a label by default")
	}
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version": 1, "label_max_words": 5}`), 0o644)
	s.Refresh()
	if n := s.ix.Doc("doctor.zortex").NodeAt(3); n == nil || n.Type != syntax.KindLabel {
		t.Fatalf("five words allowed: a label (%+v)", n)
	}
	expect(t, ts, "/n/links2.zortex", 200, `href="/n/doctor.zortex#L3"`)
	// the file gone: the default again
	os.Remove(filepath.Join(dir, ".z", "syntax.json"))
	s.Refresh()
	if syntax.MaxLabelWords() != syntax.DefaultMaxLabelWords {
		t.Fatal("default restored")
	}
}
