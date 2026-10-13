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
| morning | **Plan the day.** Today's calendar next to ranked candidates: tasks on key results come first, the further their key result is behind schedule the higher; then tasks of projects that only have an area; then the rest. Due dates, priority and the TODO project add on top. Key results are listed most behind first, areas without a current objective first. | `:ZortexPlan` (`<leader>zm`) |
| during | **Work.** On the web home page the clocks (pomodoro, timer, stopwatch) count against the task you're working on, by default the current calendar entry, and add it to the task's `@spent(...)`. | `zortex serve` |
| evening | **Daily review.** Since the last daily review (a skipped evening rolls into the next, at most a week): objectives and key results against the time passed, XP earned and how much of it was on key results, time spent per task, what you completed, calendar tasks left (put them on another day with `:ZortexPlan`), overdue, due by tomorrow. | `:ZortexReview day` (`<leader>zW`) |
| weekly | **Weekly review.** The same plan summary over seven days, then overdue and due tasks, stale and unscheduled projects, projects without a next action, key results without projects, areas without projects or without an objective, projects with neither a key result nor an area, broken links. Every line links to its source. | `:ZortexReview` (`<leader>zw`) |

"Behind schedule" is the share of the objective's window that has passed
minus the key result's progress: a key result at 20% when half the quarter
is gone is 30% behind.

## XP

Two tracks, one source of truth:

1. **Mastery** (areas): long-term growth. Each area is a skill that levels
   up over years on a steep curve (`1000 × level^2.5`). An area's total is its
   own XP plus `area.bubble` (75%) of each sub-area's.
2. **Seasons**: short-term momentum. A season is a date window; the XP
   earned inside it levels you through tiers on a gentle curve
   (`100 × level^1.2`). With no season started by hand, the season is the
   calendar quarter, the same window as `3M-YYYY-Qn` objectives.

Every award counts for both at once: a **season share** (all work, at full
value) and a **Mastery share** that depends on how the work serves the plan.
So seasons measure effort, Mastery measures effort pointed somewhere. Keeping
the two parallel (rather than converting a season into Mastery when it ends)
means Mastery moves the day the work is done, and the same notes always give
the same totals.

### Where XP comes from

| source | when | worth | Mastery share |
|---|---|---|---|
| **Project task** | a task in a project is checked; dated by its `@done(...)` | the project's pool, paid out over its tasks on the curve below | 100% when a key result links the project (`project.key_result`), else 20% (`project.area`) |
| **Project done** | the project heading is marked `@done(...)` | whatever of the pool the curve hasn't paid yet | as above |
| **Key result** | its linked projects are all done, or it is checked; dated by its `@done` or the last completion | `key_result.base_xp` (30) × the objective's priority × importance | 100%, to the objective's areas |
| **Objective** | marked `@done(...)` | `objective.base_xp × time span` (`3M`≈Q, `1Y`, `5Y`…) × priority × importance | 100% to its areas; not counted for seasons |
| **Task** | a checked task anywhere else (calendar, any note) | `task.base_xp × size × priority × importance` | 10% (`task.area`) to its own `@a(...)` |

**Which areas.** An award's Mastery share is split over its areas on
harmonic weights (1, ½, ⅓, …), first listed first:

- work on a project a key result links: the objectives' areas, then the
  project's own (or inherited) `@a`, then the task's;
- other work: the task's own `@a`, then the project's.

A project's **pool** is `@xp(n)` when given, else `project.base_xp ×
@size(...)` (× priority × importance), else the sum of its tasks' XP. Tasks
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
not for seasons or the reviews.

### Read off the notes

Nothing is recorded when you check a task: `services/xp/ledger` rebuilds
every award from the notes whenever one changes. Unchecking, archiving, or
editing a note on your phone simply changes the result. Only seasons (their
names and dates) and the levels last announced are stored. An earlier version
kept a transaction log and running totals; they drifted (double counting,
XP kept after unchecking, lost completions from other devices), and deriving
removes that whole class of problems.

## Using it

| command | |
|---|---|
| `:ZortexPlan` (`<leader>zm`) | plan a day |
| `:ZortexReview day` / `:ZortexReview` | daily / weekly review |
| `:ZortexXPStats` (`<leader>zxs`) | season, projects in progress, recent awards, areas |
| `:ZortexXPExplain` (`<leader>zxe`) | how the project at the cursor earned its XP, award by award |
| `:ZortexXPAreas` (`<leader>zxa`) | top areas |
| `:ZortexSkillTree` (`<leader>zk`) | season progress and the area tree |
| `:ZortexSeasonStart` / `SeasonStatus` / `SeasonEnd` | a season of your own instead of the quarter |

On the web, the home page of `zortex serve` shows the season (level, tier,
progress), XP per day for two weeks, top areas and recent awards. Neovim
publishes that summary after every change (`.z/xp_summary.json`, and
`POST /api/xp` when `server.enabled`; `xp.publish = false` turns it off). The
server writes time tracked per day to `.z/time_spent.json`, which the daily
review reads.

From Lua: `require("zortex").query.xp()` (plain data: season, areas, daily
XP, recent awards), `require("zortex.services.xp.ledger").get()` (every
award, each with `aligned` = `"kr"`, `"area"` or nil),
`require("zortex.services.agenda").review({ scope = "day" })` (the review's
data). Events: `xp:awarded`, `xp:removed`, `season:leveled_up`,
`area:leveled_up`.

## Configuration

`Config.xp` (see `lua/zortex/config.lua`): `sources.task|project|key_result|objective`
(`base_xp`, `sizes`, `season`, `area`, `key_result`), `area.level_curve`,
`area.bubble`, `season.level_curve`, `season.tiers`, `season.follow_quarter`,
`modifiers.priority_multipliers|importance_multipliers`,
`stamp_done_on_save`, `notify_min`. The task `sizes` are also the effort
points that weigh project and key-result progress; a size the config doesn't
list counts 1. The planner's weights are `require("zortex.services.planner").weights`.

## Keeping it honest

The risk of any points system is optimizing for points (Goodhart's law). The
XP here only follows work you planned, and pays most for work on what you
said matters this quarter. Use it as a mirror in the reviews, not as a
target: the useful number is the share of your week that went to key
results, not the total.
