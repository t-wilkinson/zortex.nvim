# Planning and XP

How the pieces fit: what you plan (areas, objectives, key results,
projects, tasks), the daily and weekly loop that keeps the plan honest, and
the XP that mirrors it. The note format is in [Syntax.md](Syntax.md); the
projects and areas API in [Projects.md](Projects.md).

## The plan

Five layers, each linking to the one above:

```
area        what you care about over years       areas.zortex       # 1 Personal / ## 1.1 Health
objective   what you'll change this period        okr.zortex         ## 3M-2026-Q4 Build steady habits @a(1.1)
key result  how you'll know                       okr.zortex         - KR1: [ ] Bake every weekend [P/#2.2 Bake a loaf]
project     the work that moves a key result      projects.zortex    ## 2.2 Bake a good sourdough loaf
task        the next step                         anywhere           - [ ] Feed the starter twice a day @size(sm)
```

- **Areas** are headings (and labels) in `areas.zortex`, nested: `1.2` is part
  of `1`.
- **Objectives** are headings in `okr.zortex` named `SPAN-YEAR-PERIOD Title`;
  `3M-2026-Q4` runs October to December (also `6M-2026-H2`, `1M-2026-03`,
  `1Y-2026-Y`). Give each its area: `@a(1.1)`.
- **Key results** are `- KRn:` items under an objective. Link the projects
  that move them: `[P/#2.2 Bake a good sourdough loaf]`. A key result's
  progress is its projects' effort points done (`@size` weighs tasks); a key
  result without projects counts its checkbox.
- **Projects** are headings in `projects.zortex` (or any note tagged `@P`),
  **tasks** the checkbox items under them.

**The canonical path** is task → project → key result → objective → area:
the objective decides which area the work serves. A project can also carry
its own `@a(...)` for work no objective covers (keeping a home, routine
health). That's legitimate, but it is maintenance; growth goes through an
objective.

## The loop

| when | what | command |
|---|---|---|
| morning | **Plan the day.** Yesterday's open tasks come along ([carried forward](#the-day-on-the-calendar)). Today's calendar next to ranked candidates: tasks on key results come first, the further their key result is behind schedule the higher; then tasks of projects that only have an area; then the rest. Due dates, priority and the TODO project add on top. Key results are listed most behind first, areas without a current objective first. Put projects (`P`, with their open tasks) and tasks (`p`) on the day. | `:ZortexPlan` (`<leader>zm`) |
| during | **Work.** Tick tasks on the calendar (Neovim or the web); their project tasks are ticked with them. On the web home page the clocks (pomodoro, timer, stopwatch) count against the task you're working on, by default the first open task of the current calendar block, and add it to its `@spent(...)`. | `zortex serve` |
| evening | **Daily review.** Since the last daily review (a skipped evening rolls into the next, at most a week): what is left in the inbox (from Neovim or the web app's "Add to inbox"), objectives and key results against the time passed, XP earned and how much of it was on key results, time spent per task, what you completed, calendar tasks left (tomorrow's plan carries them), overdue, due by tomorrow. | `:ZortexReview day` (`<leader>zW`) |
| weekly | **Weekly review.** The inbox and the same plan summary over seven days, then overdue and due tasks, stale and unscheduled projects, projects without a next action, key results without projects, areas without projects or without an objective, projects with neither a key result nor an area, broken links. Every line links to its source. | `:ZortexReview` (`<leader>zw`) |

"Behind schedule" is the share of the objective's window that has passed
minus the key result's progress: a key result at 20% when half the quarter
is gone is 30% behind.

## The day on the calendar

A day is a block of `calendar.zortex`. Projects and their tasks go on it
without duplicating them: a task on the calendar is the project's task.

```
2026-10-15:
09:00 [P/#1 Programming/#1.4 - zortex]
  - [ ] [./-Improve website] @id(aB3x9)
  - [ ] [./-Change task sizes] @id(Kp2wQ)
14:00 Call the bank about [P/#2 Home/-Mortgage]
- [ ] Buy milk
```

- **Copies.** `- [ ] [./-Improve website] @id(aB3x9)` has the `@id` of the
  project's `- [ ] Improve website @id(aB3x9)`: lines with the same `@id` in
  the calendar and the project notes are one task. It is done when any of
  them is checked (its `@done` the earliest), so the project's progress, the
  planner and the reviews see it done; it earns its XP once, as a project
  task (with the project's areas). Toggling one, in Neovim or on the web,
  toggles the others, so the notes read the same; a hand edit that leaves
  them apart still counts once. `@spent` adds up over the copies.
- **Blocks.** `09:00 [P/#1.4 - zortex]` with tasks nested under it: the
  tasks' `[./-Item]` links continue the block's link
  ([Syntax](Syntax.md#links)), and while the block runs the web app's clocks
  count against its first open task, then the next once that one is ticked.
- **References.** A line without a checkbox whose link points at a task
  (`14:00 Call the bank about [P/#2 Home/-Mortgage]`) stands for it: it
  shows the task's state, and toggling it toggles the task. A timed line
  can't hold a checkbox, so this is how a task gets a time.
- **Carrying forward.** Planning today (`:ZortexPlan`, or
  `:ZortexCarryForward` / the web home page's **Carry** button) copies the
  open tasks of the last 14 days to today with the same `@id`, under their
  block (today's, when today already has one for the same link, say from the
  day's template), and marks the old lines `[>]` (carried: neither open nor
  done, kept as the record of that day). Repeating entries (`@repeat`) stay.

In the planner, `p` puts a task on the day as a copy (under its project's
block when the day has one; the task gets an `@id` if it has none), `P` a
project as a block with all of its open tasks, and `<CR>` / `i` / `o` the
task's text and link at the cursor (a reference, ready for a time). The
weekly review lists ids that don't line up (a copied project line, a copy
whose link points at another task); so does the web app's `/broken`.

## XP

XP is **estimated work**: `@size` says how long something takes, in hours
(`xp.sizes`), and an hour is worth 10 XP (`xp.xp_per_hour`). Priority
(`@p1` ×1.5, `@p2` ×1.2) and importance (`@i1`, `@i2`) multiply it. One scale
for everything:

| `@size` | task | project | objective |
|---|---|---|---|
| xs | 15m | 2h | 5h |
| sm | 30m | 6h | 10h |
| md | 1h | 12h | 30h |
| lg | 2h | 20h | 60h |
| xl | 3h | 40h | 120h |
| larger | 2xl 5h … 5xl 20h | epic 160h, legendary 480h, mythic 1,000h, ultimate 2,500h | |

An unsized task counts as md; a project without `@size` is the sum of its
tasks; an objective without `@size` is the projects its key results link (else
md). `@xp(n)` sets a project, key result or objective outright. Tracked time
(`@spent`, from the web clocks) is shown in the reviews but not paid: XP
rewards finishing what you planned, not hours logged. **`:ZortexXPGuide`
(`<leader>zxg`) shows these tables from your own config**, and what the task,
project or objective at the cursor is worth.

Two measures come out of it:

1. **Mastery** (areas): long-term growth. Every award has a Mastery share
   that depends on how the work serves the plan (`xp.alignment`), split over
   the areas it is linked to. Each area levels up over years: level `L` at
   `316 × L^2.5` XP, so level 2 is about 180 hours of aligned work and level
   10 about 10,000. An area's total is its own XP plus `area.bubble` (75%) of
   each sub-area's.
2. **Seasons**: progress on this period's objectives. A season is a date
   window (by default the calendar quarter, the window of `3M-YYYY-Qn`
   objectives); its progress is the progress of the objectives in it,
   weighted by their XP, so a large, important objective moves it more than a
   small one. Tiers are thresholds on that progress (Bronze 25%, Silver 50%,
   Gold 70%, Platinum 85%, Complete 100%: every objective done).

So the season measures how far you got with what you planned, and Mastery
how much work you pointed at your areas, with the most for work on key
results. Both are read off the same notes and move the day the work is done.

### Where XP comes from

| source | when | worth | Mastery |
|---|---|---|---|
| **Project task** | a task in a project is checked; dated by its `@done(...)` | the project's pool, paid out over its tasks on the curve below | ×1.0 when a key result links the project (`alignment.key_result`), else ×0.2 when it has an `@a` (`alignment.project_area`) |
| **Project done** | the project heading is marked `@done(...)` | whatever of the pool the curve hasn't paid yet | as above |
| **Key result** | its linked projects are all done, or it is checked; dated by its `@done` or the last completion | 20% (`completion_bonus`) of its objective's XP, split over the objective's key results | ×1.0, to the objective's areas |
| **Objective** | marked `@done(...)` | 20% of its XP | ×1.0, to its areas |
| **Task** | a checked task anywhere else (calendar, any note); a calendar copy of a project task (same `@id`) is that project task instead | its hours × 10 × priority × importance | ×0.1 (`alignment.task_area`) to its own `@a(...)` |

An md objective (30 hours, 300 XP) finished through its key results earns
300 for the work, 60 for its key results and 60 when you mark it done: 420
Mastery XP. The same 30 hours on projects with only an `@a` earn 60.

**Which areas.** An award's Mastery share is split over its areas on
harmonic weights (1, ½, ⅓, …), first listed first:

- work on a project a key result links: the objectives' areas, then the
  project's own (or inherited) `@a`, then the task's;
- other work: the task's own `@a`, then the project's.

A project's **pool** is `@xp(n)` when given, else its `@size` in hours × 10
(× priority × importance), else the sum of its tasks' XP. Tasks
moved to `z/archive.*` still count under the same project, so archiving never
takes XP away.

**The project curve** front-loads the first tasks (overcoming inertia),
pays steadily through the middle and rewards finishing:

| project | initiation | execution | completion |
|---|---|---|---|
| 1-5 tasks | first task 40% | next 2: 40% | the rest 20% |
| 6-15 tasks | first 3: 25% | 60% of tasks: 50% | the rest 25% |
| 16+ tasks | first 15%: 20% | middle 70%: 50% | the rest 30% |

Every pool pays out exactly 100% once all its tasks are done. Adding tasks to
a project re-spreads the same pool over more tasks.

**Dates.** Toggling a task adds `@done(today)`. A task checked by hand gets
`@done(today)` when the note is saved, if it was newly checked in that edit
(`xp.stamp_done_on_save`). Completions without a date count for Mastery but
not for the reviews.

### Read off the notes

Nothing is recorded when you check a task: `services/xp/ledger` rebuilds
every award from the notes whenever one changes. Unchecking, archiving, or
editing a note on your phone simply changes the result. Only seasons (their
names and dates, and the final progress and tier of past ones) and the
levels and tier last announced are stored. An earlier version
kept a transaction log and running totals; they drifted (double counting,
XP kept after unchecking, lost completions from other devices), and deriving
removes that whole class of problems.

## Using it

| command | |
|---|---|
| `:ZortexPlan` (`<leader>zm`) | plan a day |
| `:ZortexReview day` / `:ZortexReview` | daily / weekly review |
| `:ZortexXPGuide` (`<leader>zxg`) | how XP is calibrated: hours per `@size`, Mastery, tiers; and what the line at the cursor is worth |
| `:ZortexXPStats` (`<leader>zxs`) | season, projects in progress, recent awards, areas |
| `:ZortexXPExplain` (`<leader>zxe`) | how the project at the cursor earned its XP, award by award |
| `:ZortexXPAreas` (`<leader>zxa`) | top areas |
| `:ZortexMasteryTree` (`<leader>zk`) | the season's objectives and tier, and the area tree |
| `:ZortexSeasonStart` / `SeasonStatus` / `SeasonEnd` | a season of your own instead of the quarter |

On the web, the home page of `zortex serve` shows the season (progress,
tier, its objectives), Mastery XP per day for two weeks, top areas and recent
awards. Neovim
publishes that summary after every change (`.z/xp_summary.json`, and
`POST /api/xp` when `server.enabled`; `xp.publish = false` turns it off). The
server writes time tracked per day to `.z/time_spent.json`, which the daily
review reads.

From Lua: `require("zortex").query.xp()` (plain data: season, areas, daily
XP, recent awards), `require("zortex.services.xp.season").status()` (the
season's objectives, progress and tier), `require("zortex.services.xp.ledger").get()` (every
award, each with `aligned` = `"kr"`, `"area"` or nil),
`require("zortex.services.agenda").review({ scope = "day" })` (the review's
data). Events: `xp:awarded`, `xp:removed` (Mastery), `season:tier_reached`,
`area:leveled_up`.

## Configuration

`Config.xp` (see `lua/zortex/config.lua`): `xp_per_hour`,
`sizes.task|project|objective` (hours per `@size`), `alignment.key_result|project_area|task_area`,
`completion_bonus`, `area.level_curve`, `area.bubble`, `season.tiers`
(`{ name, at }`, `at` a share of the season's objectives), `season.follow_quarter`,
`modifiers.priority_multipliers|importance_multipliers`,
`stamp_done_on_save`, `notify_min`. The task sizes are also the effort points
that weigh project and key-result progress; a size the config doesn't list
counts as md. The planner's weights are `require("zortex.services.planner").weights`.

## Keeping it honest

The risk of any points system is optimizing for points (Goodhart's law). The
XP here only follows work you planned, and pays most for work on what you
said matters this quarter. Inflating a size does raise its XP, but then
Mastery stops meaning hours of real work, which is the only thing that makes
it worth reading; the guide's table is there to keep estimates honest and
comparable. When an estimate turns out wrong, change the size (or set
`@xp(n)`) and every total follows. Use it as a mirror in the reviews, not as a
target: the useful number is the share of your week that went to key
results, not the total.
