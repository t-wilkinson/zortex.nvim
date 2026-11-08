package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/t-wilkinson/zortex.nvim/app/edit"
	"github.com/t-wilkinson/zortex.nvim/app/syntax"
)

// A whole line "Label::" is a label at any length; Neovim's
// syntax.label_max_words and label_pattern reach the server through
// .z/syntax.json and decide which "Key:" lines read as labels.
func TestSyntaxFileLabelRule(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	defer syntax.SetLabelRule(syntax.DefaultMaxLabelWords, "")
	note := "@@Doctor\n\nQuestions for the doctor before the visit::\n- the knee\n"
	os.WriteFile(filepath.Join(dir, "doctor.zortex"), []byte(note), 0o644)
	os.WriteFile(filepath.Join(dir, "links2.zortex"), []byte("@@L2\n\n- [Doctor/:Questions for the doctor before the visit]\n"), 0o644)
	s.Refresh()
	if n := s.ix.Doc("doctor.zortex").NodeAt(3); n == nil || n.Type != syntax.KindLabel {
		t.Fatalf("a label at any length (%+v)", n)
	}
	expect(t, ts, "/n/links2.zortex", 200, `href="/n/doctor.zortex#L3"`)

	key := func(line string) string { return syntax.Classify(line).Key }
	if key("Questions for the doctor: none") != "" {
		t.Fatal("four words: not a label key by default")
	}
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version": 1, "label_max_words": 5}`), 0o644)
	s.Refresh()
	if key("Questions for the doctor: none") != "Questions for the doctor" {
		t.Fatal("five words allowed: a label key")
	}
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version": 1, "label_max_words": 0, "label_pattern": "^%u%u+$"}`), 0o644)
	s.Refresh()
	if key("TODO: fix") != "TODO" || key("Wins: x") != "" || key("Wins:: x") != "Wins" {
		t.Fatal("the pattern alone decides one-colon keys")
	}
	// the file gone: the default again
	os.Remove(filepath.Join(dir, ".z", "syntax.json"))
	s.Refresh()
	if syntax.MaxLabelWords() != syntax.DefaultMaxLabelWords || syntax.LabelPattern() != "" {
		t.Fatal("default restored")
	}
}

// "group_days": false in .z/syntax.json (Neovim's ui.calendar.group_days =
// false): days the server adds make no month headings.
func TestSyntaxFileGroupDays(t *testing.T) {
	s, dir, _ := newTestServer(t, "")
	defer edit.SetGroupDays(true)
	s.checkSyntaxFile()
	if !edit.GroupDays() {
		t.Fatal("on by default")
	}
	os.WriteFile(filepath.Join(dir, ".z", "syntax.json"), []byte(`{"version": 1, "label_max_words": 3, "group_days": false}`), 0o644)
	s.Refresh()
	if edit.GroupDays() {
		t.Fatal("off from the file")
	}
	os.Remove(filepath.Join(dir, ".z", "syntax.json"))
	s.Refresh()
	if !edit.GroupDays() {
		t.Fatal("on again without the file")
	}
}

// Labels, bold headings and label keys show one colon on the page.
func TestLabelsShowOneColon(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	note := "@@Colons\n\nNext steps:::\nIdeas @p1::\n  Nested idea::\nWins:: shipped it\n- Notes:: a keyed item\n- KR1: [ ] Key result\nKey: value\nA much longer key than three: text\n"
	os.WriteFile(filepath.Join(dir, "colons.zortex"), []byte(note), 0o644)
	s.Refresh()
	body := expect(t, ts, "/n/colons.zortex", 200,
		`<div class="ln bold-heading" id="L3">Next steps:</div>`,
		`<div class="ln label" id="L4">Ideas `,
		`<div class="ln label" id="L5" style="--ind:2">Nested idea:</div>`,
		`<span class="key">Wins: </span>shipped it`,
		`<span class="key">Notes:</span>`,
		`<span class="key">KR1:</span>`,
		`<span class="key">Key: </span>value`,
	)
	if strings.Contains(body, "::") {
		t.Errorf("a double colon shows: %s", body[strings.Index(body, "::")-80:strings.Index(body, "::")+20])
	}
	if strings.Contains(body, `<span class="key">A much longer`) {
		t.Error("a long one-colon key is plain text")
	}
}
