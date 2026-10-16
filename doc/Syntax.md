# Zortex syntax

This is the complete reference for the `.zortex` note format. The grammar
is implemented once, in `lua/zortex/core/syntax.lua`; the web app's Go
parser (`app/syntax`) is tested against the same fixtures. Every example in
the two tables marked "checked" below is a line of
[`tests/fixtures/syntax`](../tests/fixtures/syntax), and `tests/test_syntax_doc.lua`
checks that the parser gives it the kind or span listed. If the parser and
this page ever disagree, the test fails.

## A note

```zortex
@@Projects
@@P
@Me
@size(lg)

# 1 Programming @p1
## 1.4 - zortex @a(4.1)
**Next steps:**
Ideas:
- [ ] Write the server guide @size(sm) @due(2026-10-20)
- [x] Improve website @done(2026-10-12)
```

A note is a `.zortex` file under `notes_dir`. Notes go in `notes_dir`
itself; `z/` holds resources (PDFs, images, books) and archives
(`z/archive.*.zortex`). Notes in subfolders work too; folders starting with
`.` are skipped.

**Header.** The note starts with its header: `@@Name` lines (the first is
the article name, the rest are aliases) and `@Tag` lines. Blank lines are
skipped; the header ends at the first other line. A header line like
`@size(lg)` or `@a(4.1)` is an attribute of the whole note: a standalone
project's size, or its area.

**Sections.** Headings, bold headings and labels open sections. Each has a
level, and a section ends at the next section of the same or a higher level
(a lower number):

| Section | Level |
|---|---|
| article (the header) | 0 |
| `#` … `######` heading | 1–6 |
| `**Bold heading:**` | 7 |
| `Label:` | 8 + indentation, so indented labels nest |

Everything else (list items, text, blocks) belongs to the section above it.
Nothing inside a code or math block is structure.

## Lines (checked)

<!-- check: lines -->
| Example | Kind | Notes |
|---|---|---|
| `@@Syntax sample` | `article` | In the header: the article name, then aliases |
| `@Example` | `tag` | In the header: a tag (`@P` makes the note a project) |
| `@size(lg)` | `tag` | In the header: an attribute of the note |
| `# Heading one @p1 @a(4.1)` | `heading` | `#` to `######` and a space |
| `#NotHeading` | `text` | the space is required |
| `**Bold heading:**` | `bold_heading` | the colon is inside the closing `**`; only spaces may follow |
| `**Not a heading**` | `text` | no colon: just bold text |
| `**Old style**:` | `label` | the colon outside: a label whose text is bold |
| `Label:` | `label` | text ending in `:` |
| `  Indented label:` | `label` | indentation nests labels |
| `- Bulleted label:` | `label` | a bullet item ending in `:` is a label too |
| `Label: text after colon` | `text` | nothing may follow the colon |
| `Not a label: one. Two: three` | `text` | no sentence (`. `) in a label |
| `Trailing spaces label:   ` | `text` | no trailing spaces after a label's colon |
| `- plain bullet with [^1]` | `item` | a bullet: `-` and a space |
| `+ not a bullet` | `text` | bullets are `-` only |
| `*not a bullet*` | `text` | italic text, not a bullet |
| `1. numbered` | `item` | ordered: a number or one letter, `.` and a space |
| `B. lettered` | `item` | |
| `1.not ordered` | `text` | the space is required |
| `- [ ] Open task @size(sm) @due(2026-10-12)` | `item` | a task: `[ ]` open, `[x]` done; text must follow |
| `- [x] Done task @done(2026-10-08)` | `item` | `@done(date)` dates the completion (XP counts it then) |
| `- [>] Carried task @id(aB3x9)` | `item` | carried to a later day: neither open nor done ([Planning](Planning.md#the-day-on-the-calendar)) |
| `  - [ ] Nested task` | `item` | indented items nest (tasks under a task share its `@size`: [task groups](Planning.md#xp)) |
| `- KR1: [ ] Key result [P/#1 Programming]` | `item` | a keyed item: `Key:` then an optional checkbox (key results) |
| `14:00 Timed entry [Flipping]` | `item` | a time item (calendar events) |
| `16:00 - 17:00 Ranged entry` | `item` | a time range |
| `- 09:00 Bulleted time` | `item` | a bullet whose text starts with a time (not a time item) |
| `09:00-10:30x not a range` | `text` | |
| `\| col a \| col b \|` | `table` | rows start and end with `\|` |
| `> a quote` | `quote` | `> ` and a space |
| `\| not a quote` | `text` | `\|` without a closing `\|` is text |
| `>not quote` | `text` | the space is required |
| `` ```lua `` | `fence` | ` ``` ` or `~~~` fences; the closing fence uses the same character |
| `# not a heading` | `code` | inside a fence |
| `$$` | `math_fence` | display math block |
| `[^1]: The footnote with https://example.com and ./images/pic.png` | `footnote` | a footnote definition |
| `Key: value text with @home and an email me@example.com.` | `text` | a paragraph line |

## Inline (checked)

<!-- check: inline -->
| Example | Span | Notes |
|---|---|---|
| `[Link/#Heading]` | `link` | see Links below |
| `![Live link]` | `live_link` | a link shown in place (the digest note) |
| `@[cars parts]` | `tag_search` | lines tagged `@cars` and `@parts` (words: all of them; commas: any); see Tag searches below |
| `!@[R/rust async]` | `tag_search` | the same search shown in place: a table on the web; see Tag searches below |
| `[text](https://example.com)` | `markdown` | a markdown link |
| `[^1]` | `footnote_ref` | a footnote reference |
| `https://example.com` | `url` | |
| `./images/pic.png` | `filepath` | `./`, `../`, `~/` or `/` paths, relative to the note |
| `@size(sm)` | `attribute` | `@key(value)` |
| `@p1` | `attribute` | a bare `@word`; must start a word (`me@example.com` is text) |
| `` `code` `` | `code` | |
| `$x^2$` | `math` | inline math |
| `**bold**` | `bold` | |
| `*italic*` | `italic` | |
| `10:30` | `time` | |

`[ ]`, `[x]` and other one-character brackets are not links, and nothing is
a span inside code.

## Attributes

Attributes are `@key(value)` or bare `@word`. These are understood (tasks,
projects, calendar entries):

| Attribute | Meaning |
|---|---|
| `@id(4Fz9q)` | a task's id (added when a task is created); the same `@id` in the calendar and a project note is one task ([Planning](Planning.md#the-day-on-the-calendar)) |
| `@done(2026-10-12)` | when a task was completed |
| `@due(2026-10-20)` | due date |
| `@p1` `@p2` `@p3`, `@i1` … `@i3` | priority, importance |
| `@size(xs)` … `@size(5xl)`, or `@sm`, `@lg`, … | task size (projects also `epic`, `legendary`, `mythic`, `ultimate`); sizes weigh XP |
| `@a(4.1)`, `@area(1.2/Fitness)` | area link: `4.1` is `[A/#4.1]`, `1.2/Fitness` is `[A/#1.2/:Fitness]`; comma-separated for several |
| `@progress(3/5)` | a project's progress (written back on request) |
| `@xp(500)` | a project's XP pool |
| `@2h`, `@dur(90m)`, `@est(3h)` | duration and estimate |
| `@spent(1h25m)` | time worked on it, added by the web app's clocks ([time tracking](../app/README.md#time-tracking)) |
| `@notify(15)`, `@n(0, 30)`, `@n(0, end)` | calendar: notify minutes before the start (several allowed; every timed line notifies at its time by default, `@n(no)` turns it off); `end` also notifies when a range ends |
| `@event` | calendar: something fixed that you plan around (an appointment, a flight), not a block you planned; the web month grid marks its day |
| `@repeat(weekly)` | calendar: repetition |
| `@slides(2)` | in a header: the heading level that starts a slide ([slides](../app/README.md#slides)) |
| `@step`, `@steps` | slides: reveal a line, or each item of a slide, one at a time |
| `@rust`, `@home`, `@ai-model` | any other bare `@word`: a tag, found by tag searches (`@[rust]`; see [Tag searches](#tag-searches)) |

## Embeds

`![…]` shows what it links to in place instead of linking to it. A path to
an image (`![./images/pic.png]`, `![https://example.com/a.png]`) is shown
as the image on the web, and a video (`![./clips/demo.mp4]`) as a player; `!@[tags]` shows a tag search as a table (Tag
tables, below); other embeds (`![Live link]`) are links for now and are
reserved for showing zortex data in place. Math is `$inline$`,
`$$display$$` or a block between `$$` lines, typeset with KaTeX on the web.

## Links

A link is `[` components separated by `/` `]`, resolved left to right; each
component narrows the places the previous ones found. Matching is
case-insensitive and by prefix: `[P/#1.4]` finds `## 1.4 - zortex`.

| Component | Example | Finds |
|---|---|---|
| article | `[Projects]`, `[P]` | notes named (or aliased) so, then notes tagged with it: `[P/…]` reaches `projects.zortex` and every `@P` note |
| `@` tag | `[@Cars]` | notes whose header has the tag |
| `#` heading | `[P/#1.4 - zortex]` | a heading at any depth in the range |
| `:` label | `[A/#1.2/:Fitness]` | a label |
| `*` bold | `[Note/*Next steps]` | a bold heading or bold text |
| `-` item | `[O/#Current/-KR1]` | a list item by its key or text (a markdown link counts as its text: `-The Rust Book`) |
| `%` query | `[Note/%sparkplug]` | any line containing the text |
| `>` follow | `[R/#Rust/>The Rust Book]` | a link in the range, by its text or its line's text; following it opens what that link points to (last component only) |

- `[/#Local heading]` (leading `/`) resolves in the current note.
- `[./-Item]` (`./` and a typed component: `-`, `#`, `:`, `*`, `>`) continues
  the link of the line it's nested under: below `09:00 [P/#1.4 - zortex]`,
  `  - [ ] [./-Improve website]` is `[P/#1.4 - zortex/-Improve website]`. The
  parent is the nearest less-indented line above with a link (a parent can be
  relative too). Any other `./` link is a file path (`[./scan.pdf]`).
- `>` links to the links in a note, so a list of resources can be linked by
  name: `[R/#Rust/>The Rust Book]` opens the book from
  `- [The Rust Book](https://doc.rust-lang.org/book) @rust`. It matches a
  markdown link's text, a link's definition, a URL or a path, or the text of
  the line it is on, by prefix; `>` alone is every link in the range. When
  several match, Neovim shows a picker and the web app a page to pick from.
  The picker lists each link's title, target and section with a preview of
  its line: `<CR>` opens the link, `<C-l>` goes to its line.
- The first match is the link's target; when there are more, the quickfix
  list (Neovim) or the link page (web app) shows them all.
- Archived notes (tagged `@Archive`, or `z/archive.*.zortex`) are skipped
  unless a component is `@Archive`.
- Generated links keep only `A-Z a-z 0-9 _ - ( ) . :` of a heading
  (`#4 Learning & Education` is written `#4 Learning`); the prefix match
  still finds it.

`doc/Architecture.md` (Links) has the exact resolution rules.

## Tag searches

`@[tags]` finds the lines tagged with bare `@words`: `@[rust]` finds
`- [The Rust Book](https://doc.rust-lang.org/book) @rust`. Before the last
`/` is where to look, written as a link; without it, the note the search is
in; `*` is every note:

| Search | Finds |
|---|---|
| `@[rl ai-model]` | lines in this note tagged both `@rl` and `@ai-model` (`@rl @ai-model` too) |
| `@[rl, ai-model]` | lines tagged `@rl` or `@ai-model` |
| `@[rust async, rl]` | lines tagged both `@rust` and `@async`, or `@rl` |
| `@[R/#Rust/async]` | lines tagged `@async` in the Rust section of Resources |
| `@[@Library/rl]` | lines tagged `@rl` in every note tagged `@Library` |
| `@[*/rust]` | lines tagged `@rust` in every note |

A tag on a heading, bold heading or label tags every line in its section:
under `## Embedded @embedded`, `- [The Embedded Rust Book](…) @rust` matches
`@[embedded rust]`. Tags in a note's header select notes (`@[@Library/…]`)
and are not inherited by its lines.

**Resources and their notes.** A list item that holds a link is a resource;
the lines nested under it, labels included, are notes about it. A heading
that is nothing but a link and attributes is a resource too, and its
section is its notes, sub-headings and all. Notes match a tag search only by
their own tags: not the resource's, nor those of the sections above it.

```zortex
# Rust @rust
- [The Rust Book](https://doc.rust-lang.org/book) @status(reading)
  - chapters 1-8 first
  Ownership:
    - moves vs borrows
  - Full notes: [Rust book notes]

### [Rust for Rustaceans](https://rust-for-rustaceans.com) @status(next)
Read after the book.
#### Setup
- `cargo new`
```

`@[rust]` finds the two resources (and the heading), not their notes.

**Tag tables.** `!@[…]` on a line of its own shows the search in place: on
the web, a table of the lines it finds, with a column for the item, the link
it holds and its kind (web, pdf, book, note…), its other tags, each
`@key(value)` attribute the rows use (`@status(reading)`, `@rating(4)`) and
where it is. An item's notes show under it: all of them up to three lines,
else the first two and an "All notes" button that opens them in a panel,
followed by the first note they link to. Sort by any column; filter by
text, kind or tag. An `@[…]` link that finds several lines opens the same
table, and so does a bare tag on the web: `@rust` links to `@[*/rust]`. In
Neovim `!@[…]` follows like `@[…]`.

```zortex
# Reading
!@[*/book]

- [The Rust Book](https://doc.rust-lang.org/book) @book @status(reading) @rating(5)
  - chapters 1-8 first
```

**Tag indexes.** A label whose lines are all tag searches, or items that
group them, is an index: on the web, rows of chips (each with how many
lines it finds) over one shared table; choosing a chip shows its table and
puts the search in the address (`#tags=R/rl`), so the choice can be linked.
A chip's name is the text before its search, or the search itself; an item
without a search groups the items under it, and its chip searches all of
them (when they look in the same place). The label's lines end at the
first blank line; index labels separated only by blank lines share one
widget. In Neovim the lines are ordinary items: `gx` on one follows its
search, and `gx` on the label opens the index in the web app
(`:ZortexLinkOpenWeb`, `<leader>zgX`, opens any line's link there).

```zortex
Topics:
- AI @[R/rl, ai-model]
  - Reinforcement learning @[R/rl]
  - Models @[R/rl ai-model]
- Embedded
  - RTOS @[R/rtos embedded]
  - Rust @[R/rust]
```

## Special notes

| Note | Name | What it holds |
|---|---|---|
| `projects.zortex` | `@@Projects` / `@@P` | headings are projects and sub-projects; checkbox items are their tasks. Any note tagged `@P` is a project too |
| `areas.zortex` | `@@Areas` / `@@A` | headings and labels are areas (`# 1 Personal`, `## 1.2 Health`, `Fitness:`) |
| `okr.zortex` | `@@Objectives` / `@@OKR` | headings like `## 3M-2026-Q1 Title` are objectives; `- KRn: [ ] …` items are key results; project links on a KR drive its progress |
| `calendar.zortex` | `@@Calendar` | `YYYY-MM-DD:` labels with entries under them: `- [ ] task`, `14:00 event`, `16:00 - 17:00 event`, `- note` |
| `structure.zortex` | `@@Structure` | links to your notes; notes nothing here links to are listed as unlinked. A note tagged `@Structure` adds all its links; a note with a top-level `# Structure` heading adds the links in that section: its own sub-notes, so a hub note can own its part of the tree |
| `inbox.zortex` | `@@Inbox` | tasks and notes added from the web app |

`setup()` creates these from short templates in a new notes folder;
`:ZortexInit` adds missing ones later. See [Projects.md](Projects.md) for
projects and areas in depth.
