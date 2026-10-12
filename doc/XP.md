# XP

Two progression loops, one source of truth:

1. **Areas (the main quest)**: long-term mastery. Each PARA area is a skill
   that levels up over years on a steep curve (`1000 × level^2.5`).
2. **Seasons (the battle pass)**: short-term momentum. A season is a date
   window (a quarter, say); the XP earned inside it levels you through tiers
   on a gentle curve (`100 × level^1.2`).

## XP is read off the notes

Nothing is recorded when you check a task. `services/xp/ledger` rebuilds
every award from the notes whenever one changes:

| source | when | worth | areas get |
|---|---|---|---|
| **Project task** | a task in a project is checked; dated by its `@done(...)` | the project's pool, paid out over its tasks on the curve below | `project.area` (20%) of it, or `project.key_result` (100%) when a key result links the project |
| **Project done** | the project heading is marked `@done(...)` | whatever of the pool the curve hasn't paid yet | same as above |
| **Task** | a checked task anywhere else (calendar, any note); dated by `@done(...)` | `base_xp × size × priority × importance` | `task.area` (10%) to its own `@a(...)` |
| **Objective** | an OKR objective marked `@done(...)` | `objective.base_xp × time span` (`3M`≈Q, `1Y`, `5Y`…) × priority × importance | `objective.area` (100%) to its `@a(...)`; not counted for seasons |

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

**Areas.** An award's area share is split over its areas, most specific first
(the task's own `@a`, then the project's, then the areas of objectives whose
key results link the project), on harmonic weights (1, ½, ⅓, …). An area's
total is its own XP plus `area.bubble` (75%) of each sub-area's total, so
progress in a sub-skill counts towards the broader one.

**Seasons** count the `season` share of every award dated inside the window
(`:ZortexSeasonStart [name] [end] [start]`; a start in the past counts what
you already did since then). Ending a season archives its final XP and level.

**Dates.** Toggling a task adds `@done(today)`. A task checked by hand gets
`@done(today)` when the note is saved, if it was newly checked in that edit
(`xp.stamp_done_on_save`). Completions without a date count for areas but
not for seasons.

## Why derived?

The previous version kept a transaction log and running totals, and they
drifted: a standalone task's completion crashed the handler (its id was read
from the wrong field), unchecking a standalone task kept its XP, starting a
season wiped the log but not the area totals (so completing more tasks of a
project counted its earlier tasks again), the curve never paid out the last
phase, area shares ignored the configuration, the largest share went to
whichever area came first in a hash table, and tasks checked by hand, on a
phone, or in a renamed project were never counted. Deriving XP from the
notes removes the whole class of problems: the same notes always give the
same XP.

## Using it

| command | |
|---|---|
| `:ZortexXPStats` (`<leader>zxs`) | season, projects in progress, recent awards, areas |
| `:ZortexXPExplain` (`<leader>zxe`) | how the project at the cursor earned its XP, award by award |
| `:ZortexXPAreas` (`<leader>zxa`) | top areas |
| `:ZortexSkillTree` (`<leader>zk`) | season progress and the area tree |
| `:ZortexSeasonStart` / `SeasonStatus` / `SeasonEnd` | seasons |

On the web: the home page of `zortex serve` shows the season (level, tier,
progress), XP per day for two weeks, top areas and recent awards. Neovim
publishes that summary after every change (`.z/xp_summary.json`, and
`POST /api/xp` when `server.enabled`; `xp.publish = false` turns it off).

From Lua: `require("zortex").query.xp()` (plain data: season, areas, daily
XP, recent awards), `require("zortex.services.xp.ledger").get()` (every
award), `require("zortex").xp` (views). Events: `xp:awarded`, `xp:removed`,
`season:leveled_up`, `area:leveled_up`.

## Configuration

`Config.xp` (see `lua/zortex/config.lua`): `sources.task|project|objective`
(`base_xp`, `sizes`, `season`, `area`, `key_result`), `area.level_curve`,
`area.bubble`, `season.level_curve`, `season.tiers`,
`modifiers.priority_multipliers|importance_multipliers`,
`stamp_done_on_save`, `notify_min`. Task sizes not listed in `sizes` (`2xl`
… `5xl`) scale with the same size points as project progress.

## Keeping it honest

The risk of any points system is optimizing for points (Goodhart's law). The
XP here only follows work you planned: projects, their tasks and objectives.
Use it as a mirror in the weekly review, not as a target.
