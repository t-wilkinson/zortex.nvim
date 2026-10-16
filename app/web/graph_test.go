package web

import (
	"net/url"
	"strings"
	"testing"
)

var graphNotes = map[string]string{
	"structure.zortex": "@@Structure\n\n# Library\n## Learning\n- [Rust]\n- [Reading]\n",
	"rust.zortex":      "@@Rust\n\nIntro, see [Reading].\n\n# Structure\n## Books\n- [Rust book notes]\n  - [Async]\n\n# Notes\n- [Loose]\n",
	"reading.zortex": "@@Reading\n\n# Shelf\n!@[*/book]\n\n# Rust\n" +
		"- [The Rust Book](https://doc.rust-lang.org/book) @book @rust @status(reading) @rating(5)\n" +
		"  - chapters 1-8 first\n" +
		"- [Programming Rust](./programming-rust.pdf) @book @rust @status(done)\n" +
		"# Other @ml\n- [Sutton](https://example.com/rl.pdf) @book @id(x1)\n- not a book @rust\n",
	"programming-rust.pdf":   "%PDF",
	"rust-book-notes.zortex": "@@Rust book notes\n",
	"async.zortex":           "@@Async\n\nBack to [Rust].\n",
	"loose.zortex":           "@@Loose\n",
}

func TestTagTable(t *testing.T) {
	ts := newSlidesServer(t, graphNotes)
	body := expect(t, ts, "/n/reading.zortex", 200, `<div class="ln embed-table" id="L4"><div class="tag-table">`)
	table := body[strings.Index(body, `class="tag-table"`):]
	table = table[:strings.Index(table, `</table>`)]
	for _, want := range []string{
		`placeholder="Filter 3 rows"`,
		`data-sort="value">@status</button>`, `data-sort="value">@rating</button>`,
		`<td data-v="reading">reading</td>`, `<td data-v="5">5</td>`,
		`<a href="https://doc.rust-lang.org/book" target="_blank" rel="noopener noreferrer">doc.rust-lang.org/book</a>`,
		`<td class="tt-kind">pdf</td>`, `<td class="tt-kind">web</td>`,
		`<span class="tag">@rust</span>`, `<span class="tag">@ml</span>`, // own and inherited tags
		// short notes show under the item
		`<div class="tt-notes"><div class="ln item" data-id="L8"><span class="marker bullet" aria-hidden="true"></span><span class="body">chapters 1-8 first</span></div></div>`,
		`<a href="/n/reading.zortex#L7">Reading › Rust</a>`,
		`data-tag="rust">@rust</button>`, `data-kind="pdf">pdf</button>`,
	} {
		if !strings.Contains(table, want) {
			t.Errorf("table lacks %s", want)
		}
	}
	for _, bad := range []string{`@book`, `@id`, `not a book`, `class="attr"`} {
		if strings.Contains(table, bad) {
			t.Errorf("table has %s", bad)
		}
	}
	// the @[...] link page shows the same table
	expect(t, ts, "/link?to="+url.QueryEscape("@[*/book]"), 200, "3 tagged lines.", `class="tag-table"`, `<td data-v="reading">reading</td>`)
	// inline !@[...] in a sentence stays a link
	ts2 := newSlidesServer(t, map[string]string{"a.zortex": "@@A\n\nsee !@[*/x] here\n- b @x\n"})
	if _, _, b := get(t, ts2, "/n/a.zortex"); strings.Contains(b, "tag-table") || !strings.Contains(b, `class="tagsearch"`) {
		t.Error("inline !@[...] should render as a link")
	}
}

func TestTagTableNotes(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{
		"books.zortex": "@@Books\n\n!@[book]\n\n# Reading @book\n" +
			"- [The Rust Book](https://doc.rust-lang.org/book) @rust\n" +
			"  - chapters 1-8 first\n" +
			"  Ownership:\n" +
			"    - moves vs borrows\n" +
			"    - [x] lifetimes\n" +
			"  - Full notes: [Rust book notes]\n" +
			"### [Rustaceans](https://rust-for-rustaceans.com) @rust\n" +
			"Read after the book.\n" +
			"#### Setup\n" +
			"- `cargo new`\n",
		"rust-book-notes.zortex": "@@Rust book notes\n\n# Ch 1\nHello\n",
	})
	body := expect(t, ts, "/n/books.zortex", 200, `class="tag-table"`)
	table := body[strings.Index(body, `class="tag-table"`):]
	table = table[:strings.Index(table, `</table>`)]
	for _, want := range []string{
		// more than three lines of notes: the first two under the item, and
		// a button for the panel with all of them (an indented label stays in
		// the item's notes)
		`<td class="tt-item"><a class="md" href="https://doc.rust-lang.org/book" target="_blank" rel="noopener noreferrer">The Rust Book</a> <div class="tt-notes"><div class="ln item" data-id="L7">`,
		`<div class="tt-more"><button type="button" class="tt-notes-btn" aria-haspopup="dialog" data-title="The Rust Book" data-note="rust-book-notes.zortex" data-note-href="/n/rust-book-notes.zortex" data-note-title="Rust book notes">All notes <span class="dim">5</span></button><template>`,
		`<div class="ln label" data-id="L8">Ownership:</div>`,
		`<div class="ln item" data-id="L9" style="--ind:2">`,
		// a resource heading: a row named by its link, its section its notes
		`<td class="tt-item"><a class="md" href="https://rust-for-rustaceans.com" target="_blank" rel="noopener noreferrer">Rustaceans</a> <div class="tt-notes">`,
		`Read after the book.`,
		`<h4 class="ln" data-id="L14">Setup`,
	} {
		if !strings.Contains(table, want) {
			t.Errorf("table lacks %s", want)
		}
	}
	// their notes aren't rows, though the heading above them is tagged; a
	// resource heading is in the section above it
	if !strings.Contains(table, `placeholder="Filter 3 rows"`) || !strings.Contains(table, `<a href="/n/books.zortex#L12">Books › Reading</a>`) {
		t.Errorf("rows: %s", table)
	}
	// no Notes column; the preview stops after two lines
	if strings.Contains(table, `data-sort="value">Notes`) {
		t.Errorf("a Notes column: %s", table)
	}
	preview := table[strings.Index(table, `<div class="tt-notes"><div class="ln item" data-id="L7">`):strings.Index(table, `<div class="tt-more">`)]
	if !strings.Contains(preview, `data-id="L8"`) || strings.Contains(preview, `data-id="L9"`) {
		t.Errorf("preview: %s", preview)
	}
	// a keyed item shows its key once
	if strings.Count(table, "Full notes:") != 1 {
		t.Errorf("key repeated: %s", table)
	}
}

func TestStructureSections(t *testing.T) {
	ts := newSlidesServer(t, graphNotes)
	// [Rust book notes] and [Async] are in rust.zortex's # Structure; [Loose] is not
	_, _, body := get(t, ts, "/api/structure")
	if !strings.Contains(body, `"rel":"loose.zortex"`) || strings.Contains(body, `"rel":"async.zortex"`) || strings.Contains(body, `"rel":"rust-book-notes.zortex"`) {
		t.Errorf("unlinked: %s", body)
	}
	if !strings.Contains(body, `"rust.zortex"`) {
		t.Errorf("rust.zortex is a source: %s", body)
	}

	// /graph: the hub opens under its place in the structure
	page := expect(t, ts, "/graph", 200, `data-rel="rust.zortex"`)
	tree := page[strings.Index(page, `id="graph-tree"`):]
	order := []string{"Library", "Learning", `data-rel="rust.zortex"`, "Books", `data-rel="rust-book-notes.zortex"`, `data-rel="async.zortex"`, `data-rel="reading.zortex"`}
	pos := 0
	for _, o := range order {
		i := strings.Index(tree[pos:], o)
		if i < 0 {
			t.Fatalf("tree: %q missing after position %d:\n%s", o, pos, tree)
		}
		pos += i
	}
	if strings.Contains(tree, `data-rel="loose.zortex"`) && !strings.Contains(page[strings.Index(page, "Not in the structure"):], `data-rel="loose.zortex"`) {
		t.Error("loose.zortex should be listed as not in the structure")
	}
}

func TestLocalGraph(t *testing.T) {
	ts := newSlidesServer(t, graphNotes)
	body := expect(t, ts, "/n/rust.zortex", 200, `<svg class="graph"`)
	g := body[strings.Index(body, `<svg class="graph"`):strings.Index(body, `</svg>`)]
	for _, want := range []string{
		`class="gn parent"><title>Structure (Library › Learning)</title>`,
		`class="gn child"><title>Rust book notes</title>`,
		`class="gn child"><title>Async</title>`,
		`class="gn link"><title>Loose</title>`,
		`class="gn link"><title>Reading</title>`,
		`class="gn self"`,
	} {
		if !strings.Contains(g, want) {
			t.Errorf("graph lacks %s", want)
		}
	}
	// Async links back to Rust, but it's already shown as a child
	if strings.Contains(g, `class="gn back"><title>Async</title>`) {
		t.Error("a child shown twice")
	}
	// a note with no links has no graph
	if _, _, b := get(t, ts, "/n/loose.zortex"); !strings.Contains(b, `class="gn back"`) {
		t.Error("loose.zortex is linked from Rust")
	}
}

func TestGraphNoDuplicates(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{
		"structure.zortex": "@@Structure\n\n- [OKR] [OKR/#Goals] [OKR/#Vision]\n- [Inbox]\n- [Inbox]\n  - [Async]\n",
		"okr.zortex":       "@@OKR\n\n# Goals\n# Vision\n",
		"inbox.zortex":     "@@Inbox\n",
		"async.zortex":     "@@Async\n",
	})
	page := expect(t, ts, "/graph", 200)
	for _, rel := range []string{"okr.zortex", "inbox.zortex"} {
		if n := strings.Count(page, `data-rel="`+rel+`"`); n != 1 {
			t.Errorf("%s listed %d times", rel, n)
		}
	}
	if strings.Contains(page, "(above)") {
		t.Error("a repeated line is marked as listed above")
	}
	// what is indented under the repeat nests under the one entry
	inbox := page[strings.Index(page, `data-rel="inbox.zortex"`):]
	if !strings.Contains(inbox[:strings.Index(inbox, "</section>")], `data-rel="async.zortex"`) {
		t.Error("Async isn't under Inbox")
	}
}

func TestGraphCardsAndTags(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{
		"structure.zortex": "@@Structure\n\n- [Inbox]\n\n# Life\n- [Areas]\n  - [Health]\n    - [Sleep]\n      - [Naps]\n",
		"inbox.zortex":     "@@Inbox\n@Work\n",
		"areas.zortex":     "@@Areas\n",
		"health.zortex":    "@@Health\n@Body\n@Work\n",
		"sleep.zortex":     "@@Sleep\n",
		"naps.zortex":      "@@Naps\n",
		"loose.zortex":     "@@Loose\n@Body\n",
	})
	page := expect(t, ts, "/graph", 200,
		`<section class="gt-card"><h2><a class="gt-note" href="/n/structure.zortex"`, // the loose notes
		`<section class="gt-card"><h2>Life <span class="gt-n dim" title="Notes in it">4</span></h2>`,
		`data-tags="body work">Health</a>`,
		`<details><summary><a class="gt-note" href="/n/sleep.zortex"`, // two levels down: starts closed
		`<span class="gt-more dim" title="Notes under it">+1</span>`,
		`data-tag="body" data-name="Body"`, `data-tag="work" data-name="Work"`,
		`data-rel="loose.zortex" data-links="" data-tags="body">Loose</a>`,
		`id="graph-q" class="graph-q" data-slash`, `/static/graph.js`)
	if strings.Contains(page, `href="/tags"`) {
		t.Error("the top bar still has Tags")
	}
	if !strings.Contains(page, `href="/graph" aria-current="page"`) {
		t.Error("Graph isn't the current tab")
	}
}

func TestGraphBulletGroups(t *testing.T) {
	ts := newSlidesServer(t, map[string]string{
		"structure.zortex": "@@Structure\n\n- Zortex\n    - [Inbox]\n\n- [Me]\n    - [Me/#Contacts]\n    - [Blog]\n\n- The arts\n    - [Art]\n        - [Design]\n    - Plain leaf\n",
		"inbox.zortex":     "@@Inbox\n",
		"me.zortex":        "@@Me\n\n# Contacts\n",
		"blog.zortex":      "@@Blog\n",
		"art.zortex":       "@@Art\n",
		"design.zortex":    "@@Design\n",
	})
	page := expect(t, ts, "/graph", 200,
		`<section class="gt-card"><h2>Zortex <span class="gt-n dim" title="Notes in it">1</span></h2>`,
		`<section class="gt-card"><h2>The arts <span class="gt-n dim" title="Notes in it">2</span></h2>`)
	arts := page[strings.Index(page, `<h2>The arts`):]
	if !strings.Contains(arts[:strings.Index(arts, "</section>")], `data-rel="art.zortex"`) {
		t.Error("Art isn't under The arts")
	}
	if strings.Count(page, `data-rel="me.zortex"`) != 1 {
		t.Error("[Me/#Contacts] under [Me] listed Me again")
	}
	if strings.Contains(page, "Plain leaf") {
		t.Error("a bullet with nothing under it is shown")
	}
}
