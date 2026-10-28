package web

import (
	"strings"
	"testing"
)

// Links to files elsewhere on the computer are never broken: zortex links
// and markdown links, "~/" and absolute paths; a "/" path in the notes
// folder still opens there.
func TestOSPathLinksAreNotBroken(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{
		"a.zortex": "@@A\n\n" +
			"- [~/Documents/tax.pdf]\n" +
			"- [/home/me/notes/plan]\n" +
			"- [the scan](~/scans/a.png)\n" +
			"- [the share](/srv/share/b.txt)\n" +
			"- ![~/Pictures/cat.png]\n" +
			"- [/z/here.pdf] and [/#Nowhere]\n",
		"z/here.pdf": "%PDF",
	})
	page := expect(t, ts, "/n/a.zortex", 200,
		`<span class="zl ospath" title="On your computer: ~/Documents/tax.pdf">`,
		`<span class="zl ospath" title="On your computer: /home/me/notes/plan">`,
		`<span class="zl ospath" title="On your computer: ~/scans/a.png">the scan</span>`,
		`<span class="zl ospath" title="On your computer: /srv/share/b.txt">the share</span>`,
		`<span class="zl ospath" title="On your computer: ~/Pictures/cat.png">`,
		`href="/f/z/here.pdf"`)
	if n := strings.Count(page, `zl broken`); n != 1 {
		t.Errorf("%d broken links, want 1 ([/#Nowhere])", n)
	}
	broken := expect(t, ts, "/broken", 200, "#Nowhere")
	for _, bad := range []string{"tax.pdf", "/home/me", "a.png", "b.txt", "cat.png"} {
		if strings.Contains(broken, bad) {
			t.Errorf("/broken lists %s", bad)
		}
	}
}
