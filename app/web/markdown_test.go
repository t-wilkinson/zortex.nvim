package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMarkdownFile(t *testing.T) {
	s, dir, ts := newTestServer(t, "")
	files := map[string]string{
		"z/md/readme.md": "---\ntitle: Front\n---\n" +
			"# Title *x*\n\n" +
			"Some *em* and $x_1 + y^2$ math\nwrapped line  \nafter a break\n\n" +
			"Setext\n======\n\n" +
			"- Key: value\n- [ ] task\n\n" +
			"@tag and [Zortex Name] stay text\n\n" +
			"![pic](img/p.png \"Pic\") ![gone](nope.png)\n" +
			"[other](other.md#title-x) [up](#setext) [ref][1] [Short]\n\n" +
			"***\n\n" +
			"$$\n\\int_0^1 f\n$$\n\n" +
			"| a | b |\n|---|---|\n| $y$ | [Short] |\n\n" +
			"<script>alert(1)</script>\n\n" +
			"[1]: https://example.com \"Ex\"\n[short]: ./other.md\n",
		"z/md/other.md":     "# x\n",
		"z/md/img/p.png":    "png",
		"z/md/page.html":    "<p>hi</p>",
		"z/md/plain.txt":    "plain",
		"z/md/notes.zortex": "@@MD links\n\n- [readme](z/md/readme.md)\n",
	}
	for rel, content := range files {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(content), 0o644)
	}
	s.Refresh()

	body := expect(t, ts, "/f/z/md/readme.md", 200,
		`<details class="frontmatter" id="L1">`,
		`<h1 class="ln" id="L4"><span class="anchor" id="title-x"></span>Title <em>x</em>`,
		`<p class="md-p">`,
		`<span class="ln text" id="L6">Some <em>em</em> and <span class="math">x_1 + y^2</span> math</span>`,
		`<span class="ln text" id="L7">wrapped line</span><br>`,
		`<h1 class="ln" id="L10"><span class="anchor" id="setext"></span>Setext`,
		`<span class="body">Key: value</span>`,
		`@tag and [Zortex Name] stay text`,
		`<img class="embed" src="/raw/z/md/img/p.png" alt="pic" title="Pic" loading="lazy">`,
		`<a class="md broken" title="File not found">gone</a>`,
		`<a class="md" href="/f/z/md/other.md#title-x">other</a>`,
		`<a class="md" href="#setext">up</a>`,
		`<a class="md" href="https://example.com" title="Ex"`,
		`<a class="md" href="/f/z/md/other.md">Short</a>`,
		`<hr class="ln" id="L21">`,
		`<pre class="math-block" id="L23">`,
		`<td><span class="math">y</span></td>`,
		`&lt;script&gt;alert(1)&lt;/script&gt;`,
		`href="/f/z/md/readme.md?source=1">source</a>`,
	)
	for _, bad := range []string{"<script>alert", `class="zl`, `class="attr"`, `class="key"`, `[1]: https`} {
		if strings.Contains(body, bad) {
			t.Errorf("markdown page has %q", bad)
		}
	}

	// the source, with a way back
	src := expect(t, ts, "/f/z/md/readme.md?source=1", 200, `<pre class="view text">---`, `href="/f/z/md/readme.md">rendered</a>`)
	if strings.Contains(src, `class="md-p"`) {
		t.Error("?source=1 rendered the Markdown")
	}
	// HTML too; other text files have nothing to switch to
	expect(t, ts, "/f/z/md/page.html", 200, `<iframe class="view doc"`, `href="/f/z/md/page.html?source=1">source</a>`)
	expect(t, ts, "/f/z/md/page.html?source=1", 200, `<pre class="view text">&lt;p&gt;hi&lt;/p&gt;</pre>`, `>rendered</a>`)
	if b := expect(t, ts, "/f/z/md/plain.txt", 200, `<pre class="view text">plain</pre>`); strings.Contains(b, "?source=1") {
		t.Error("plain text has a source link")
	}
	// a note's link to a Markdown file lands on the rendered page
	expect(t, ts, "/n/z/md/notes.zortex", 200, `href="/f/z/md/readme.md"`)
}
