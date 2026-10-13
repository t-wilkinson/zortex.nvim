# Changelog

All notable changes to zortex.nvim and `zortex serve`. The project follows
[semantic versioning](https://semver.org): until 1.0 a minor version may
change the note format or the configuration; such changes are listed under
**Upgrading**.

## [0.1.0] - unreleased

The first release for people other than the author.

### Neovim plugin

- One grammar (`core/syntax`) for every feature, documented in
  [doc/Syntax.md](doc/Syntax.md) and checked against the parser by a test.
- Structural search, links with completion and preview, backlinks and broken
  links from a persistent link index.
- Projects, areas, objectives and key results as entities with progress,
  a weekly review, a day planner, a calendar view with iCal import/export.
- XP and seasons read off completed tasks; a skill tree. Mastery (area XP)
  follows the plan: work on a project a key result links goes to the
  objective's areas first; a key result reached is an award of its own;
  with no season started by hand, the season is the calendar quarter.
- The day planner ranks key-result work first, the further behind schedule
  the higher; a daily review (`:ZortexReview day`) next to the weekly one,
  both opening with objectives, XP on key results and time spent.
- [doc/Planning.md](doc/Planning.md) explains the plan, the loop and XP.
- First run: a new notes folder gets calendar, projects, areas, okr,
  structure and inbox notes from short templates (`:ZortexInit` later).
- `:checkhealth zortex`: Neovim version, the notes folder, key notes, broken
  links, old-style bold headings, optional integrations.
- `:help zortex`, generated from the actions and the configuration defaults.
- Works without telescope.nvim and nvim-cmp; the pickers say they need
  telescope instead of failing.

### Server (`zortex serve`)

- Rendered notes, search, file browser, tags, broken links, the notes not
  linked from Structure; live updates while you edit elsewhere.
- Home page: today's calendar, the pomodoro (shared with Neovim), timers,
  alarms and a stopwatch, time tracking on tasks (`@spent`), season XP.
- Calendar notifications, pomodoro changes, timers and alarms through ntfy.
- `-writable`: check off tasks, edit, add, move and delete lines, add to the
  inbox, from any browser.
- `GET /api/digest`: the coming days of the calendar for any mail service.
- An optional login (`-auth-file`, `ZORTEX_AUTH`) for setups without a proxy
  that has one; a warning when listening beyond localhost without a login.
- Released as binaries for Linux and macOS and as
  `ghcr.io/t-wilkinson/zortex`; a NixOS module.

### Upgrading (from the author's earlier versions)

- **Neovim 0.10** or newer is required.
- **Bold headings** are `**Text:**` only; `**Text**` and `**Text**:` lines are
  now bold text and a label. `:ZortexMigrate` rewrites them (it lists every
  change first).
- **Highlights** follow your colorscheme. The old palette is
  `ui = { highlights = { preset = "rose-pine" } }`.
- **Calendar icons** are plain Unicode; the Nerd Font set is in a comment in
  `config.lua` (`ui.calendar.icons`). `ui.calendar.icon_width` is gone.
- **Size points** (project and key-result progress) come from
  `xp.sources.task.sizes` (md = 1); `constants.SIZE_POINTS` is gone.
- **Removed:** the AWS/SES providers and the digest email
  (`:ZortexDigestSend`, `:ZortexDigestPreview`), Neovim's timers and alarms
  (`:ZortexTimerStart`, `:ZortexAlarm`, ... — they are on the web home page
  now), the old Node app (`legacy/`) and its VimL bridge (`autoload/`).

[0.1.0]: https://github.com/t-wilkinson/zortex.nvim/releases/tag/v0.1.0
