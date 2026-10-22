# Example notes

A small notes folder that uses most of the format: the six key notes
(`structure`, `projects`, `areas`, `okr`, `calendar`, `inbox`), four more
notes beside them, and an image in `z/` (resources and archives). The
screenshots in the main README are of it.

Try it on a copy:

```sh
cp -r doc/example /tmp/zortex-example
nvim /tmp/zortex-example/structure.zortex
```

with `require("zortex").setup({ notes_dir = "/tmp/zortex-example" })`, or
serve it:

```sh
zortex serve -dir /tmp/zortex-example -data /tmp/zortex-example-data -writable
```

What to look at:

- `structure.zortex` links to everything (the web app lists notes it doesn't
  link to under "Not in Structure").
- `projects.zortex`: projects as headings, tasks with `@size`, `@due`,
  `@done`, `@spent`; `@area(1.2)` links a project to an area.
- `okr.zortex`: objectives (`## 3M-2026-Q4 …`) under their season's
  heading, whose key results link to projects, which drives their progress.
- `calendar.zortex`: dated days with timed entries; entries link to tasks
  (`[P/#2.1/-Chapters 4-6]`), so the day planner and time tracking know
  what you're working on.
- `sourdough.zortex`: headings, bold headings (`**Feeding:**`), labels
  (`Mix:`), a table, a quote, and links back into the structure.
- `format.zortex`: a short tour of the format in one note: headings,
  labels, inline markup, math, code, the kinds of links, tasks and
  attributes.
- `zortex-talk.zortex`: a note that is also a slide deck (the **slides**
  link on its page): speaker notes, step-by-step items, an image and math.
