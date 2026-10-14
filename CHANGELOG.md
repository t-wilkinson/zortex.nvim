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
- XP read off completed tasks, calibrated in hours: `@size` is estimated
  time (`xp.sizes`), 10 XP an hour. Mastery (area XP) follows the plan: work
  on a project a key result links counts in full, to the objective's areas
  first; key results reached and objectives done add a completion bonus.
  `:ZortexXPGuide` shows the calibration from your config.
- Seasons are progress on their objectives (weighted by objective XP), with
  tiers at 25/50/70/85/100%; with no season started by hand, the season is
  the calendar quarter. A skill tree shows both.
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
- Links to links: a `>` component (`[R/#Rust/>The Rust Book]`) opens the link
  it matches instead of the line it is on, with a picker when several match
  and completion after `>`; its preview shows the link's line and the notes
  nested under it.
- Tag searches take a scope: `@[R/#Rust/async]`, `@[@Library/rl & ai-model]`,
  `@[*/rust]`; a tag on a heading tags its section. `-` finds a list item by
  its markdown link's text (`[R/#Rust/-The Rust Book]`).

### Server (`zortex serve`)

- Rendered notes, search, file browser, tags, broken links, the notes not
  linked from Structure; live updates while you edit elsewhere.
- `>` links go straight to the link they match, or to a page listing them.
- `@[...]` tag searches list the tagged lines they find (they used to run a
  text search).
- Home page: today's calendar, the pomodoro (shared with Neovim), timers,
  alarms and a stopwatch, time tracking on tasks (`@spent`), the season's objectives and Mastery XP.
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
- **XP configuration**: `xp.sources` is replaced by `xp.xp_per_hour`,
  `xp.sizes.task|project|objective` (hours per `@size`), `xp.alignment` and
  `xp.completion_bonus`; `constants.SIZE_POINTS` is gone. Effort points
  (project and key-result progress) are the task hours (md = 1).
- **Seasons** have no levels: `xp.season.tiers` are `{ name, at }` with `at`
  a share of the season's objectives (was `required_level`), and
  `xp.season.level_curve` is gone. Past seasons keep their final XP and level
  in the history. The area curve is recalibrated to hours
  (`xp.area.level_curve = { base = 316, exponent = 2.5 }`: level 10 is about
  10,000 hours).
- **Removed:** the AWS/SES providers and the digest email
  (`:ZortexDigestSend`, `:ZortexDigestPreview`), Neovim's timers and alarms
  (`:ZortexTimerStart`, `:ZortexAlarm`, ... — they are on the web home page
  now), the old Node app (`legacy/`) and its VimL bridge (`autoload/`).

[0.1.0]: https://github.com/t-wilkinson/zortex.nvim/releases/tag/v0.1.0
