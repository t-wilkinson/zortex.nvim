# Philosophy

Why zortex is a personal wiki rather than a Zettelkasten, in the author's
words.

## Why it looks like this

Zortex started as an attempt at a Zettelkasten: every line a separate
thought with its own id and a few tags, and notes found by querying tags. It
was interesting, but it didn't help much in practice. The flat pile of
thoughts had real costs:

- It was complicated.
- Tags did the organizing, so I never had to think about how ideas fit
  together, and I rarely thought about anything deeply.
- Nothing was the one place a concept lived: there was no single source of
  truth.

What I actually wanted turned out to be a personal Wikipedia: tens to
hundreds of articles, each the place for one subject, that I can search in a
few keystrokes and that link to each other. Zortex is built around that:

- **Articles, not fragments.** A note is an article (`@@Sourdough`) with
  headings, labels and lists. Links name places by structure,
  `[Sourdough/#Method]`, so they read like what they point at and survive
  being typed from memory.
- **A Structure note** links to every other note: the map of the whole
  wiki. Folded, it shows the main domains; opened, it goes as deep as you
  like. A note can appear in several places, so the map is a graph where
  it needs to be, while the depth lives in the articles themselves. Notes
  nothing in Structure links to are listed, so nothing gets lost.
- **Connections inside the articles.** Where a Zettelkasten keeps the
  links between ideas in tags and ids, here a section of an article says
  how it relates to another one, with a link: what Wikipedia does.
- **Tags where they help.** A bare `@word` on a line (`@rust`, `@home`) is
  a tag, and a tag search (`@[rust async]`) gathers every line or section
  carrying it, in place. They cut across articles without replacing them.
- **An inbox** for what has no home yet: a line added from Neovim or the
  web app's "Add to inbox", sorted into an article or a project later in
  the daily review.
- **Archives** for what you're done with but want to keep: `z/archive.*`
  notes (or notes tagged `@Archive`) are kept but left out of links,
  project lists and search ranking.

The same notes hold the rest of life too: projects, areas, objectives and
the calendar are articles with a few conventions ([Planning](Planning.md)),
so a project, its tasks and the notes about it are all one link apart.

## The name

- Zettelkasten (German for "slip box": *Zettel*, a slip of paper, and
  *Kasten*, a box) is the note-taking system made famous by Niklas Luhmann,
  a very prolific sociologist.
- Cortex, Latin for bark, as in "cerebral cortex" and "neocortex", the part
  of the brain central to thinking. Zortex is meant to be a second brain.
