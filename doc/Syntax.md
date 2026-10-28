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
## 1.4 - zortex @area(4.1)
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
`@size(lg)` or `@area(4.1)` is an attribute of the whole note: a standalone
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
| `**Bold then colon**:` | `text` | the colon outside the stars: bold text, not a label |
| `Label:` | `label` | text ending in `:` |
| `Three word label:` | `label` | up to three words (`@attributes` don't count) |
| `A line of four words:` | `text` | longer, it is a sentence ending in a colon, not a label |
| `*A longer label like this one:*` | `label` | a longer label: between stars, colon inside |
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
| `16:00 [ ] timed task` | `item` | a timed task: a checkbox after the time (or the range, `16:00 - 17:00 [x] timed range task`) |
| `16:00 - not a [ ] task` | `item` | a time item whose text has brackets later on, not a task |
| `- 09:00 Bulleted time` | `item` | a bullet whose text starts with a time (not a time item) |
| `09:00-10:30x not a range` | `text` | |
| `\| col a \| col b \|` | `table` | rows start and end with `\|` |
| `> a quote` | `quote` | `> ` and a space |
| `---` | `rule` | three or more dashes alone on a line: a separator, a slide break in a deck ([slides](Web.md#slides)) |
| `--- not a rule` | `text` | nothing may follow the dashes; `***` and `- - -` aren't rules either |
| `\| not a quote` | `text` | `\|` without a closing `\|` is text |
| `>not quote` | `text` | the space is required |
| `` ```lua `` | `fence` | ` ``` ` or `~~~` fences; the closing fence uses the same character |
| `# not a heading` | `code` | inside a fence |
| `$$` | `math_fence` | display math block |
| `[^1]: The footnote with https://example.com and ./images/pic.png` | `footnote` | a footnote definition |
| `[^Smith, 2020]: Smith, J. (2020). A book about notes.` | `footnote` | ids may have spaces and commas: an author-year citation |
| `[^Smith & Jones, 2019a] Smith, J. and Jones, K. (2019). A paper.` | `footnote` | at the start of a line the colon may go (a space after the `]`, or nothing) |
| `[^1]. not a footnote: no colon, no space` | `text` | anything else after the `]` makes it text |
| `Key: value text with @home and an email me@example.com.` | `text` | a paragraph line |

**What counts as a label.** A line that passes the rules above (ends in
`:`, no `. `, nothing after the colon) is a label when it has at most
`syntax.label_max_words` words (default 3; `@attributes` don't count).
Neovim writes the number to `.z/syntax.json` so the web app reads labels
the same way. For anything else, `syntax.is_label = function(text, line)`
(`text`: before the colon, without the bullet and `@attributes`; `line`:
the whole line) decides in Neovim alone: return `true` or `false`, or `nil`
for the word count. A regex is a Lua pattern inside it
(`return text:match("^%u[%w ]+$") ~= nil`). It
runs only on candidate lines, so it costs about what the word count does;
the web app can't run it, so it keeps the word count there. Starred labels
(`*A longer label like this one:*`) are labels whatever their length.

## Inline (checked)

<!-- check: inline -->
| Example | Span | Notes |
|---|---|---|
| `[Link/#Heading]` | `link` | see Links below |
| `[the zortex plugin](P/#1.4 - zortex)` | `link` | the same link shown as its text ([Display text](#display-text)) |
| `![Live link]` | `live_link` | a link shown in place: an image or video on the web; other targets are reserved for showing zortex data in place |
| `![a cat](./images/pic.png)` | `live_link` | an image with its alt text, as in Markdown |
| `@[cars parts]` | `tag_search` | lines tagged `@cars` and `@parts` (words: all of them; commas: any); see Tag searches below |
| `!@[R/rust async]` | `tag_search` | the same search shown in place: a table on the web; see Tag searches below |
| `[text](https://example.com)` | `markdown` | a markdown link: a URL, or a file (`[the scan](z/scan.pdf)`) |
| `[^1]` | `footnote_ref` | a footnote reference |
| `[^Smith, 2020]` | `footnote_ref` | a citation: the web shows it as `(Smith, 2020)`, with the definition as its tooltip |
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

Attributes are `@key(value)` or bare `@word`. This reference writes each
in full; most have a short form that means the same. The short version of
this list is a key away: `:Zortex attributes` in Neovim (typing `@`
completes them, each with how it is written), `/attributes` on the web
(and the attribute chips of the web editor):

| Written in full | Short |
|---|---|
| `@area(4.1)` | `@a(4.1)` |
| `@notify(15)` | `@n(15)` |
| `@size(sm)` | `@sm` |
| `@dur(90m)` | `@90m` |
| `@p(1)`, `@i(1)` | `@p1`, `@i1` |

These are understood (tasks, projects, calendar entries):

| Attribute | Meaning |
|---|---|
| `@id(4Fz9q)` | a task's id (added when a task is created); the same `@id` in the calendar and a project note is one task ([Planning](Planning.md#the-day-on-the-calendar)) |
| `@done(2026-10-12)` | when a task was completed |
| `@due(2026-10-20)` | due date |
| `@p1` `@p2` `@p3`, `@i1` … `@i3` | priority, importance (`@p(1)` is the same): they rank work in the planner and the projects picker; XP only if `xp.modifiers` says so |
| `@size(xs)` … `@size(5xl)` | task size (projects also `epic`, `legendary`, `mythic`, `ultimate`); sizes weigh XP |
| `@area(4.1)`, `@area(1.2/Fitness)` | area link: `4.1` is `[A/#4.1]`, `1.2/Fitness` is `[A/#1.2/:Fitness]`; comma-separated for several. The work's area XP goes there; work with no area earns for `@a(0.1)` (`xp.default_area`), which the daily review writes when it closes ([Planning](Planning.md#area-xp-and-season-xp)) |
| `@project(1.4)`, `@project(1/1.4)`, `@project(P/#Kitchen)` | the project a line belongs to (`1.4` is `[P/#1.4]`): `m` in the daily review moves it there, dropping the attribute |
| `@someday` | a project parked on purpose: not listed as stale or unscheduled (`z` in the weekly review toggles it) |
| `@xp(500)` | a project's XP pool |
| `@ref(Smith, 2020)`, `@ref(Smith & Jones, 2019a; Lee, 2021)` | a reference, author and year (several: `;` between): tag searches find it by author, `@[*/author(smith)]` (each of `Smith & Jones`, `et al.` left off, matches too), by year, `@[*/year(2020)]`, or whole, `@[*/ref(Smith, 2020)]`. Cite it in the text with a [footnote](#footnotes-and-citations) |
| `@dur(90m)`, `@dur(2h)` | how long it takes (a calendar entry's length, a task's minutes in the planner); a calendar line with one that starts inside a running block is a break, after which the block resumes |
| `@spent(1h25m)` | time worked on it, added by the web app's clocks ([time tracking](Web.md#time-tracking)) |
| `@at(14:00)` | calendar: the line's time, as `14:00` at the start of the line does (`@from(14:00) @to(15:30)` for a range) |
| `@notify(15)`, `@notify(0, 30)`, `@notify(0, end)`, `@notify(07:30)`, `@notify` | calendar: notify minutes before the start (several allowed; every timed line notifies at its time by default, `@notify(no)` turns it off); `end` also notifies when a range ends; a time of day (`07:30`) notifies then, on the line's day. An all-day line (a date range, or an untimed line with `@notify`) notifies on its first day at `notifications.all_day_time` (09:00), minutes (`@notify(1d)`) before that |
| `@event` | calendar: something fixed that you plan around (an appointment, a flight), not a block you planned; the web month grid marks its day, and it is listed under "Coming up" (as are timed lines without a checkbox that don't link a project, and repeating notes) |
| `@share` | calendar: the line is in the server's `/calendar.ics`, which other calendars (Cozi, Google, Apple) subscribe to; nothing else of the calendar is ([Other calendars](Server.md#6-other-calendars)) |
| `@free` | calendar: a timed line that doesn't take your time: the planner's capacity line doesn't count it as busy (a calendar feed with `busy: false` writes it) |
| `@repeat(weekly)`, `@repeat(2w)`, `@repeat(mon, wed)`, `@repeat(03-14)` | calendar, `# Repeating` section only: how often the entry shows ([Planning](Planning.md#templates-and-repeating-entries)); anywhere else it is not read (the calendar note flags it) |
| `@on(sun)`, `@on(15th)`, `@on(03-14)`, `@on(2nd tue)`, `@on(last fri)`, `@on(last)` | calendar, `# Repeating` section only: which days a repeating entry lands on (`@repeat(monthly) @on(last thu)`); alone, it repeats on those days (`@on(weekdays)`) |
| `@from(2026-10-06)`, `@to(2026-12-31)` | a repeating entry: its first day (what every n counts from: `2w` needs one) and its last day, both optional otherwise; with a time instead (`@from(07:30) @to(08:15)`), a calendar line's time |
| `@born(1990)`, `@born(1961-07-02)`, `@born(Feb 1, 2000)`, `@born(07-02)` | in `# Repeating`: a birthday. A year shows the age after the text; a day (`yyyy-mm-dd`, `mm-dd-yyyy`, `mm-dd`, `Feb 1`, `February 1, 2000`) repeats it yearly on that day |
| `@for(2026-10-18)` | a repeating task's copy done on another day: the day it stands for |
| `@fold` | on a heading, label or list item with nested lines: the section starts folded in Neovim each time the note is shown (`zo` opens it until then) |
| `@slides(2)` | in a header: the heading level that starts a slide ([slides](Web.md#slides)) |
| `@step`, `@steps` | slides: reveal a line, or each item of a slide, one at a time |
| `@rust`, `@home`, `@ai-model` | any other bare `@word`: a tag, found by tag searches (`@[rust]`; see [Tag searches](#tag-searches)) |

## Footnotes and citations

`[^1]` refers to the line that starts with `[^1]:`. An id is anything but
brackets, so it can be a citation:

```zortex
- Spaced repetition beats rereading [^Smith, 2020] @ref(Smith, 2020)

[^Smith, 2020]: Smith, J. (2020). Learning that lasts. Press.
[^Lee, 2021] Lee, K. (2021). Memory. (the colon may go at the start of a line)
```

On the web a numeric footnote is a superscript and a citation (an id with a
space or a comma) reads `(Smith, 2020)`; both link to their definition and
show it on hover. In Neovim `gx` on a reference jumps to its definition.
`@ref(Smith, 2020)` on the line makes it findable by author or year
([Tag searches](#tag-searches)).

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
| `-` item | `[O/#Current/-KR1]`, `[P/-aB3x9]` | a list item by its key or text, its links without their brackets (`- To [this link]` and `- To [this link](./x)` are both `-To this link`; a markdown link counts as its text: `-The Rust Book`), or a task by its `@id` (exactly), which survives renaming the task |
| `%` query | `[Note/%sparkplug]` | any line containing the text |
| `>` follow | `[R/#Rust/>The Rust Book]` | a link in the range, by its text or its line's text; following it opens what that link points to (last component only) |

A link is coloured by what its last component names: a note (or tag), a
heading, a label, a bold heading or a list item, each its own colour
(`ZortexLinkNote`, `ZortexLinkHeading`, `ZortexLinkLabel`, `ZortexLinkBold`,
`ZortexLinkItem` in Neovim; the same kinds in the web app). Query and
follow links keep the plain link colour. Neovim shows the `/` between parts
as `›` (`ui.highlights.link_separator`, a character, or `false` for the
`/`), coloured `ZortexLinkDelimiter` (linked to `Comment`; change it with
`ui.highlights.groups = { ZortexLinkDelimiter = { fg = "#888888" } }`).

- `[/#Local heading]` (leading `/`) resolves in the current note.
- A note outside `notes_dir` (a repository's `doc/Roadmap.zortex`) resolves
  its links among the notes of its own folder: the nearest folder above it
  with a `.z/`, else the folder it is in. `[~/P/#Subaru]` (leading `~/`)
  reaches `notes_dir` from there; inside `notes_dir` it changes nothing.
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
  unless a component is `@Archive`, or nothing in the live notes matches:
  then the archives are searched too. An archive keeps its note's names
  (`z/archive.projects.zortex` starts `@@Projects`, `@@P`), so
  `[P/-Old task]` still finds a task once it's archived.
- A link to a file elsewhere on your computer is never broken:
  `[~/Documents/tax.pdf]`, `[scan](~/scans/a.png)`, `[/home/me/plan.txt]`,
  `[share](/srv/share/b.txt)`. A `/` link whose first part is a section of
  the note (`[/#Heading]`, `[/-Item]`) is a local link instead, and a `~/`
  link that finds a note (`[~/P/#Subaru]`) goes there. Neovim opens the
  file; the web app shows the path, which a browser can't open.
- Generated links keep a heading's text up to link syntax (`[ ] /`), an `@`
  or a `|` (`#Talk to Sam @p1` is written `#Talk to Sam`); the prefix match
  still finds it.

`doc/Architecture.md` (Links) has the exact resolution rules.

### Display text

`[text](definition)` is a link shown as its text: `[the zortex
plugin](P/#1.4 - zortex)` goes where `[P/#1.4 - zortex]` goes and reads
"the zortex plugin" (in Neovim the definition is concealed, on the web it is
the link's tooltip). It is Markdown's form, so imported notes keep their
link text, and the text survives a rename or a move: `:ZortexMove` rewrites the
definition only. `![alt](./pic.png)` is an image with alt text.

What is between the parentheses decides what the link is:

| Target | Is | Example |
|---|---|---|
| a URL: a scheme (`https:`, `mailto:`) or `www.` | a markdown link | `[docs](https://example.com)` |
| anything with a typed component (`#` `:` `*` `-` `%` `>` `@`, first or after a `/`) | a zortex link | `[the plan](P/#1.4)`, `[here](/#Notes)`, `[step](./-Item)`, `[car](~/P/#Subaru)` |
| a path (`./`, `../`, `/`, `~/`) or a name with a file extension | a file (a markdown link) | `[scan](./scan.pdf)`, `[scan](z/scan.pdf#page=2)` |
| anything else | a zortex link to a note | `[my projects](Projects)` |

A definition can't contain `)` there (a heading like `# Rye (dark)`, an
`@p(1)` in the link): write those `[…]` as usual. The text is matched by a
`-` component the way a markdown link's text is (`[P/-the plan]`), and by
`>`. Other forms considered and left out: a `|` alias (`[P/#1.4|the
plan]`) breaks table rows, which also use `|`, and reference-style
`[text][id]` needs a definitions block per note; `[text](…)` is the one
Markdown users already write.

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
| `@[rust is:heading]` | headings (and bold headings) tagged `@rust` |
| `@[rl is:open, rl is:label]` | open tasks tagged `@rl`, or labels tagged `@rl` |
| `@[P/is:open]` | every open task in Projects (no tag needed) |
| `@[*/status(reading)]` | lines with `@status(reading)`: an attribute by its value (case and extra spaces don't matter) |
| `@[R/author(knuth) year(1968)]` | references (`@ref(Knuth, 1968)`) by author and year; inside the parentheses spaces and commas are part of the value |

`:ZortexBrokenLinks` and the web app's `/broken` list, apart from broken
links, the tags that go nowhere: tag searches that find nothing, `[@Tag]`
links to a tag no note has, and bare tags no tag search asks for.

`is:` words narrow a group to a kind of line: `heading`, `label`, `item`
(a list item, tasks included), `task`, `open` and `done` (tasks), and
`resource` (a list item or heading that holds a link, below). A colon can't
be part of a tag, so they never clash with one.

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
| `projects.zortex` | `@@Projects` / `@@P` | headings are projects and sub-projects; checkbox items are their tasks. A heading with no task of its own and no project attribute only groups the projects under it, unless it is linked ([Planning](Planning.md)). Any note tagged `@P` is a project too |
| `areas.zortex` | `@@Areas` / `@@A` | headings and labels are areas (`# 1 Personal`, `## 1.2 Health`, `Fitness:`) |
| `okr.zortex` | `@@Objectives` / `@@OKR` | headings `## SPAN Title` and deeper are objectives (`## 3M-2026-Q4 Ship the release`: the span sets its window, see [Planning](Planning.md#the-plan)); top-level headings group them, like the season's (`# 3M-2026-Q4 Season 10 Juniper`, added by `:ZortexSeason start`); `- KRn: [ ] …` items are key results; project links on a KR drive its progress |
| `calendar.zortex` | `@@Calendar` | days with entries under them: `**YYYY-MM-DD:**` (a bold heading, what new days get, so an `Outcomes:` label nests under it) or a plain `YYYY-MM-DD:` label; entries `- [ ] task`, `14:00 event`, `16:00 - 17:00 event`, `- note`. The items right under `Outcomes:` (to the first blank line) are the day's outcomes. A day runs to the next day or heading; days are grouped under a heading per month (`# October 2026`, or `## October 2026` under `# Days`; [Months](Planning.md#months)). A timed line with an end inside a running block (`12:00 Break @15m`) is a break, and the block resumes after it ([Breaks](Planning.md#the-day-on-the-calendar)) |
| `structure.zortex` | `@@Structure` | links to your notes; notes nothing here links to are listed as unlinked. A note tagged `@Structure` adds all its links; a note with a top-level `# Structure` heading adds the links in that section: its own sub-notes, so a hub note can own its part of the tree |
| `inbox.zortex` | `@@Inbox` | tasks and notes added from the web app |
| `z/feeds/<name>.zortex` | `@@<title>`, tagged `@CalendarFeed` | written by the server from another calendar's iCal link ([Other calendars](Server.md#6-other-calendars)): days as in `calendar.zortex`, one line per event (`16:00 - 17:00 Soccer · Field 3 @notify(no)`, `- Camping` for an all-day one). The calendar shows them read-only; edits are replaced on the next change |

`:Zortex init` creates the missing ones from short templates (`setup()`
says when some are missing). See [Projects.md](Projects.md) for
projects and areas in depth.
