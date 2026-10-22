# Planning and XP

How the pieces fit: what you plan (areas, objectives, key results,
projects, tasks), the daily and weekly loop that keeps the plan honest, and
the XP that mirrors it. The note format is in [Syntax.md](Syntax.md); the
projects and areas API in [Projects.md](Projects.md).

## The plan

A vision, then five layers, each linking to the one above:

```
vision      what a good life looks like           areas.zortex       Vision: a calm home, a strong body, …
area        what you care about over years       areas.zortex       # 1 Personal / ## 1.1 Health
objective   what you'll change this season        okr.zortex         ## 3M-2026-Q4 Build steady habits @area(1.1)
key result  how you'll know                       okr.zortex         - KR1: [ ] Bake every weekend [P/#2.2 Bake a loaf]
project     the work that moves a key result      projects.zortex    ## 2.2 Bake a good sourdough loaf
task        the next step                         anywhere           - [ ] Feed the starter twice a day @size(sm)
```

- **The vision** is a `Vision:` line above the first area of `areas.zortex`,
  and each area can have its own (`Vision: fit enough to say yes to any
  hike`, or `Vision:` with lines under it): what good looks like there. The
  weekly review opens with them.
- **Areas** are headings (and labels) in `areas.zortex`, nested: `1.2` is part
  of `1`. A `Vision:` label is not an area.
- **Objectives** are headings in `okr.zortex`, `##` or deeper, that start
  with their span: `## 3M-2026-Q4 Build steady habits` runs October to
  December (also `6M-2026-H2`, `1M-2026-03`, `1Y-2026-Y`). Top-level
  headings only group them: `:ZortexSeason start` adds the season's,
  `# 3M-2026-Q4 Season 10 Juniper`, above the others, and `# Current` or
  `# Someday` work as well. Give each objective its area: `@area(1.1)`.
- **Key results** are `- KRn:` items under an objective. Link the projects
  that move them: `[P/#2.2 Bake a good sourdough loaf]`. A key result's
  progress is its projects' effort points done (`@size` weighs tasks); a key
  result without projects counts its checkbox.
- **Projects** are headings in `projects.zortex` (or any note tagged `@P`),
  **tasks** the checkbox items under them. A project is done when its tasks
  are, or when its heading has `@done(...)`: `<leader>zT` on the heading
  adds it (asking first while tasks are open) or takes it off.
- **Organizational headings** group projects without being one: a heading
  with no task of its own (done or not, sub-headings not counted) and no
  project attribute (`@size` or a bare size, `@p`, `@i`, `@due`, `@done`,
  `@xp`, `@dur` or a bare duration, `@area(…)`, `@someday`) stays out of
  the reviews, the planner, XP and `/projects`. Tags (`@cars`, for `@[…]`
  links) don't count. The projects under it are
  sub-projects of the nearest project above, and still go through it in
  their links (`[P/#Car/#Rebuild engine]`). Linking it (a key result, the
  week's focus, any note) makes it a project again when it has projects
  under it: a container whose progress is theirs.

**The canonical path** is task → project → key result → objective → area:
the objective decides which area the work serves. A project can also carry
its own `@area(...)` for work no objective covers (keeping a home, routine
health). That's legitimate, but it is maintenance; growth goes through an
objective.

## The loop

| when | what | command |
|---|---|---|
| weekly | **Weekly review.** Opens the week's entry in `reviews.zortex` (made when missing; on a weekend, the coming week's) beside the findings, top down: the inbox; then [the plan from the vision down](#the-weekly-review-top-down): the vision, each area with its vision, the objectives that name it against the time passed, their key results and the projects those link, and the area's projects no key result covers, with the gaps marked where they are; then [the week](#the-week): its focus projects, tasks put off again and again, and the active projects to pick the focus from (`f`); XP and time over seven days; overdue and due tasks, stale and unscheduled projects, projects without a next action, done projects to archive, the alignment gaps again as lists, broken links. Every line links to its source and has its [fix one key away](#review-keys); what you write goes in the note; `?` lists the keys. | `:ZortexReview` (`<leader>zw`) |
| morning | **Plan the day.** Write the day's `Outcomes:` first ([the day](#the-day-on-the-calendar)): the two or three results that would make it a success, each serving a key result or a focus project where it can. Yesterday's open tasks come along ([carried forward](#the-day-on-the-calendar)). Today's calendar next to what's [coming up](#coming-up) and ranked candidates: the week's focus projects and their tasks first; then tasks on key results, the further their key result is behind schedule the higher; then tasks of projects that only have an area; then the rest. Due dates, priority, the TODO project and how often a task was put off add on top. Key results are listed most behind first, areas without a current objective first. A project a key result links keeps the rest of its tree under it, folded: its other open tasks and each sub-project with its own (`zo` opens one). Put tasks (`p`) and projects (`P`, with their next three tasks) on the day, until the [capacity line](#capacity) says the day is full, and check how much of it is on key results. | `:ZortexPlan` (`<leader>zm`) |
| during | **Work.** Tick tasks on the calendar or a project's page (Neovim or the web); their copies are ticked with them. On the web home page the clocks (pomodoro, timer, stopwatch) count against the task you're working on, by default the first open task of the current calendar block, and add it to its `@spent(...)`. Before you stop, a line in the project's log (its web page, or a `Log:` label in the note) says where you left off. | `zortex serve` |
| evening | **Daily review.** Opens the day's entry in `reviews.zortex` (inside its week) beside the findings since the last daily review (a skipped evening rolls into the next, at most a week): first how the work done served the plan (`Work done: 3h30m · 60% on key results · 25% on areas only · 15% on neither`); what is left in the inbox (from Neovim or the web app's "Add to inbox"), with `m` to move each line to its project (an inbox line or any task marked `@project(1.4)`; without one, to `review.inbox_default` or a place you pick), the week's focus, tasks put off, objectives and key results against the time passed, XP earned, time spent per task, what you completed, what wasn't done (`t` puts it on tomorrow at the same time; tomorrow's plan carries the rest), what you finished that served neither a key result nor an area (`a` archives it to `z/archive.tasks.zortex`, or give it a home with `@project`), overdue, due by tomorrow. | `:ZortexReview day` (`<leader>zW`) |

"Behind schedule" is the share of the objective's window that has passed
minus the key result's progress: a key result at 20% when half the quarter
is gone is 30% behind.

## The weekly review, top down

The weekly review reads the plan the way it is meant to work, from why to
what:

```
# Vision, areas, objectives, key results, projects
Vision: a calm home, a strong body, and a craft I keep getting better at

## [A/#1 Personal/#1.1 Health]
Vision: fit enough to say yes to any hike
- [O/#Current/#3M-2026-Q4 Run a half marathon] 40% (expected 60% by now)
    - KR1: Run 3 times a week 50% · 10% behind [O/…/-KR1]
        - [P/#1.1 Training plan] (6/14 done) · focus
    - KR2: A 21 km long run 0% · 60% behind
        no project moves it: L links one
  - [P/#1.2 Fix the bike] (0/3 done) · area only
## [A/#2 Growth/#2.1 Reading]
  no objective this period
```

Each area shows its vision, the objectives this period that name it,
their key results and the projects those link; then the area's projects no
key result covers ("area only": upkeep, which is fine, but not growth). A
key result nothing moves, an objective with no key results, an area with no
objective: each says so where it is, with the key that fixes it.

## Review keys

On a line of either review:

| key | on | does |
|---|---|---|
| `<CR>` | any line | opens its source |
| `m` | an inbox line | moves it to its `@project`, `review.inbox_default` or a place you pick |
| `x` | a task (overdue, due, not done) | ticks it (its copies follow) |
| `d` | a task | sets or moves its `@due` (`2026-10-21`, `+3`, `tomorrow`) |
| `s` | a task / a project | puts the task on a day of the calendar (as a copy) / a block of the project with its next tasks |
| `t` | a task not done (daily review) | puts it on the next day at the same time (`[>]` on the old line) |
| `n` | a project | adds a next action to it |
| `z` | a project | parks it (`@someday`: no longer stale or unscheduled), or brings it back |
| `a` | a done project / a finished task on neither a key result nor an area | moves the project to its note's archive / the task to `z/archive.tasks.zortex` |
| `f` | a project | adds it to the week's focus, or takes it out |
| `L` | a key result | links a project to it (picked from the active ones) |
| `R` | an objective | adds a key result |
| `p` | an area | starts a project for it (a heading in the projects note with `@area(…)`) |
| `F` | a broken link | fixes it from the structural search |
| `u` | | takes the last change back, in every note it touched (`:ZortexUndo`) |

## The week

Between the quarter's objectives and the day sits the week. Each weekly
review picks the **focus projects**: the work this week is for (as many as
you like; fewer is easier to keep). They live
in the week's entry of `reviews.zortex`, one note for every review, newest
first:

```
@@Reviews

# 2026-W43
Focus:
- [P/#3 Car/#3.1 Rebuild the engine]
- [P/#2 School/#2.1 Signals and systems]
Wins:
- Head is back from the machine shop
Lessons:
- Order gaskets before tearing down

## 2026-10-21
Done:
- Lapped the valves
Blocked:
First thing tomorrow:
- Torque the head bolts in sequence
```

- `:ZortexReview` opens the week's entry and the findings beside it; on
  Saturday and Sunday it is the coming week's (`review.next_week_from`).
  `:ZortexReview day` opens the day's entry inside its week. New entries
  come from `review.week` and `review.day`; nothing in the note is
  regenerated, so it is yours to write in, and it syncs like any note.
- **Focus.** `f` on a project in the weekly review's findings adds it under
  the week's `Focus:` label, or takes it out; you can also write the links
  by hand. The planner ranks the focus projects (and their sub-projects)
  and their tasks above everything else; a week without focus keeps the
  latest earlier week's until the next weekly review. The web app lists them
  first on `/projects` and on the home page.
- **Put off.** A task on the calendar that wasn't done that day (carried on
  with `[>]`, or left open) has been put off once for each such day. The
  planner ranks it higher each time (`weights.put_off` per day, up to
  `weights.put_off_max`) with a `put off ×3` badge, and the reviews list
  every task put off on two or more days: do it, make it smaller, or drop
  it.

## Coming up

Above the candidates, the plan lists what's coming up in the next seven
days (`ui.planner.upcoming_days`; 0 hides it): the events you plan around
(`@event` lines, timed lines and calendar notes that don't link a
project), not your own planned work or tasks. The calendar view shows the
same list under the selected day.

Other calendars count too. With the server's calendar feeds
([Other calendars](Server.md#6-other-calendars)), a family calendar's events
(a Cozi member's, say) are listed among yours, read-only and labelled
(`16:00–17:00 Soccer  · cozi`); the plan lists the day's own under "From
your calendar feeds", since the calendar note beside it doesn't hold them.
Tag a line of yours `@share` and it goes the other way, into their calendar.

## Capacity

The plan buffer's second line weighs the day:

```
Capacity: 5h30m planned (4 tasks, 1 unsized) · 3h on key results · 4h free (13:20-22:00, 1h30m busy) · 1h30m over
```

- **planned**: the day's open tasks, by their `@size` hours (a copy weighs
  its project task; `@dur` on the line wins; unsized counts md);
- **on key results**: the part of that on projects an open key result
  links (or their sub-projects): how much of the day moves the quarter;
- **free**: what is left of `ui.planner.capacity.day` (from now, when
  planning today) after the timed entries that aren't project work: a
  lecture, an appointment (`09:00 - 10:30 Lecture`; one without an end
  counts `event_minutes`), and the calendar feeds' events. Blocks for a
  project (`14:00 [P/#3.1]`) are where the planned tasks happen, so they
  don't count as busy, nor does a line with `@free` (a feed with
  `busy: false` marks its events so).

It follows every `p`, `P` and edit to the day. Estimates run short (most
people plan for more than fits), so leave room: a day "to spare" by a couple
of hours is a day that holds.

## The day on the calendar

A day is a block of `calendar.zortex` under a bold label,
`**2026-10-15:**` (new days get it; a plain `2026-10-15:` reads the same).
Projects and their tasks go on it without duplicating them: a task on the
calendar is the project's task.

```
**2026-10-15:**
Outcomes:
- [ ] The website's new search is live
- Rested enough for the long run tomorrow

09:00 [P/#1 Programming/#1.4 - zortex]
  - [ ] [./-Improve website] @id(aB3x9)
  - [ ] [./-Change task sizes] @id(Kp2wQ)
11:00 - 11:45 Dentist @event @notify(30)
14:00 Call the bank about [P/#2 Home/-Mortgage]
- [ ] Buy milk
```

`:ZortexToday` (`<leader>zd`) goes straight to today's block, adding it
from the day's template when it isn't there yet (`:ZortexToday
2026-10-21` for another day); `:ZortexPlan` does the same with the
candidates beside it.

**Outcomes** come first: under an `Outcomes:` label (it nests under the
day's bold label), the two or three results that would make the day a
success, up to the first blank line. They are the day's own items (tick
them like any task), but they aren't events, and the daily review is the
place to ask whether the day's work went to them. Put one in your day
template (below) to be asked every morning.

A day reads top to bottom as you'll live it: blocks of planned work with
their tasks under them, the **events** you plan around (`@event`: an
appointment, a flight, something that happens whether or not you planned
it; the web month grid's dot marks days that have one), and loose to-dos
last. Every timed line notifies at its time, events and planned blocks
alike: a nudge to move on to the next thing, and out of deep focus.
`@notify(30)` adds a notification 30 minutes before, `@notify(no)` silences a line,
and `@notify(0, end)` also notifies when a range ends.

- **Copies.** `- [ ] [./-Improve website] @id(aB3x9)` has the `@id` of the
  project's `- [ ] Improve website @id(aB3x9)`: lines with the same `@id` in
  the calendar and the project notes are one task. It is done when any of
  them is checked (its `@done` the earliest), so the project's progress, the
  planner and the reviews see it done; it earns its XP once, as a project
  task (with the project's areas). Toggling one, in Neovim or on the web,
  toggles the others, so the notes read the same; a hand edit that leaves
  them apart still counts once. `@spent` adds up over the copies. You can
  write a copy by hand: `- [ ] [./-Improve website]` with no `@id` takes the
  task's `@id` the first time you toggle it (the task gets one first if it
  has none).
- **Blocks.** `09:00 [P/#1.4 - zortex]` with tasks nested under it: the
  tasks' `[./-Item]` links continue the block's link
  ([Syntax](Syntax.md#links)), and while the block runs the web app's clocks
  count against its first open task, then the next once that one is ticked.
- **Project blocks.** `13:00 [P/#2.2]` alone, with nothing under it: the
  calendar view and the web app list the project's next open tasks under it
  (three, `ui.planner.project_tasks`) without writing them into the note;
  ticking one (`2x` in the calendar view, the box on the web) ticks the
  project's task, and the next takes its place. While it runs, the clocks
  count against the first.
- **Timed tasks.** `16:00 [ ] Write the report` (also `16:00 - 17:00 [ ]`)
  is a task with a time: it notifies at its time like any timed line, and not once it's done. Toggling a plain timed line
  (`16:00 Report`) makes it one, keeping the time in front. Carried forward,
  it goes to today without its old time (the old line keeps it, marked
  `[>]`).
- **References.** A line without a checkbox whose link points at a task
  (`14:00 Call the bank about [P/#2 Home/-Mortgage]`) stands for it: it
  shows the task's state, and toggling it toggles the task, so a project
  task can have a time without a copy.
- **Carrying forward.** Planning today (`:ZortexPlan`, or
  `:ZortexCarryForward` / the web home page's **Carry** button) copies the
  open tasks of the last 14 days to today with the same `@id`, under their
  block (today's, when today already has one for the same link, say from the
  day's template), and marks the old lines `[>]` (carried: neither open nor
  done, kept as the record of that day). Repeating entries (`@repeat`) stay.

### Templates and repeating entries

Above the first day, the calendar note can hold two sections (any heading
level; each runs to the next heading of its level or above, or to the first
day, so a `# Days` heading after them keeps the days out of them):

```
# Templates
Weekday:
Outcomes:
- [ ]
09:00
Sunday:
12:00 Weekly review

# Repeating
## Birthdays
- Sam's birthday @repeat(03-14) @born(1990)
- Dad @repeat(yearly) @born(1961-07-02)
## Routines
12:00 [ ] Weekly review @repeat(weekly, Sunday)
- [ ] Bins out @repeat(2w) @from(2026-10-06) @at(18:00)
- 07:00 Run @repeat(mon, wed, fri) @to(2026-12-31)

# Days
```

- **Templates** are the lines a new day starts with (`:ZortexToday`, the
  planner, ticking a repeating task on a day not written yet). A label names
  which days: `Monday:` … `Sunday:` (or `Mon:` …), `Weekday:`, `Weekend:`,
  `Daily:`; the most specific wins. Everything up to the next such label is
  the template, other labels (`Outcomes:`) included.
- **Repeating entries** are the items with `@repeat(…)` in the Repeating
  section; headings, labels and plain lines around them only organize it.
  Each shows on the days it lands on, in the calendar view, the planner,
  notifications and the web calendar, without being written into them.
  `@repeat` takes `daily`, `weekly`, `monthly`, `yearly`, every n (`2d`,
  `3w`, `6m`, `2y`, counted from `@from(YYYY-MM-DD)`), days of the week
  (`sun`, `mon, wed, fri`, `weekdays`, `weekends`), a date every year
  (`03-14`) or a day of the month (`15`, `1st`); `weekly, Sunday` is every
  Sunday, `2w tue` every other Tuesday from `@from`. `@from(YYYY-MM-DD)`
  and `@to(YYYY-MM-DD)` bound it (both days included), the words a span of
  days uses elsewhere in the calendar; a `@from` or `@to` holding a time
  (`@from(07:30) @to(08:15)`) is still the entry's time. (`@since` and
  `@until`, the names before 0.1.0, are still read.) `@born(1990)` shows
  the age: `Sam's birthday (36)`; `@born(1961-07-02)` also anchors
  `yearly`.
- **A repeating task** (`[ ]`) is ticked where it shows (`x` in the calendar
  view, its box on the web): it is copied, done, into the day you did it
  (today), with `@for(2026-10-18)` when that was another day. The copy
  stands for that occurrence: on its own day it shows instead, on another
  day the occurrence takes its state (ticking it again reopens the copy).
  The copy is a calendar task like any other, so it counts for XP.

The planner (`<leader>zm`) lists projects first, each under a heading with
its ranked tasks, then key results, then to-dos (the TODO project,
`ui.planner.todo_link`, the Projects note's own tasks and calendar tasks
left open), then areas, then what is left in the inbox; the week's focus projects come
first. `?` lists its keys. In it, `p`
puts a task on the day as a copy (under its project's block when the day
has one; the task gets an `@id` if it has none), `P` a project as a block
with its next open tasks (`ui.planner.project_tasks`, three; `5P` for five;
tasks already on the day count), and `<CR>` / `i` / `o` the
task's text and link at the cursor (a reference, ready for a time). The
weekly review lists ids that don't line up (a copied project line, a copy
whose link points at another task); so does the web app's `/broken`.

## XP

XP is **estimated work**: **10 XP = 1 hour of estimated work**
(`xp.xp_per_hour`). `@size` says how long something takes, in hours
(`xp.sizes`); wherever XP is shown, its hours are next to it. Priority
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

An unsized task counts as md, except a timed task (`16:00 [ ] Task`) or the
only task under a calendar time: ticked without a size, it gets the size
nearest its block's length (its own `16:00 - 17:30` range, else until the
next timed line; by ratio, so 45 minutes is `@size(md)`), in Neovim and on the web. A project without `@size` is the sum of its
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
2. **Seasons**: progress on this period's objectives. A season is the
   calendar quarter, or a span you start with `:ZortexSeason start
   3M-2026-Q4` (written like an objective's; the quarter by default). It is
   named `Season 10 Juniper`, a number and a word whose letter moves on with
   it (`xp.season.names`), and adds its heading to `okr.zortex`,
   `# 3M-2026-Q4 Season 10 Juniper`, to put that season's objectives under;
   the heading only groups them. Its progress is the progress of the objectives in it,
   weighted by their XP, so a large, important objective moves it more than a
   small one. Tiers are thresholds on that progress (Bronze 25%, Silver 50%,
   Gold 70%, Platinum 85%, Complete 100%: every objective done).

So the season measures how far you got with what you planned, and Mastery
how much work you pointed at your areas, with the most for work on key
results. Both are read off the same notes and move the day the work is done.

### Where XP comes from

| source | when | worth | Mastery |
|---|---|---|---|
| **Project task** | a task in a project is checked; dated by its `@done(...)` | the project's pool, paid out over its tasks on the curve below | ×1.0 when a key result links the project (`alignment.key_result`), else ×0.2 when it has an `@area(…)` (`alignment.project_area`) |
| **Project done** | the project heading is marked `@done(...)` | whatever of the pool the curve hasn't paid yet | as above |
| **Key result** | its linked projects are all done, or it is checked; dated by its `@done` or the last completion | 20% (`completion_bonus`) of its objective's XP, split over the objective's key results | ×1.0, to the objective's areas |
| **Objective** | marked `@done(...)` | 20% of its XP | ×1.0, to its areas |
| **Task** | a checked task anywhere else (calendar, any note); a calendar copy of a project task (same `@id`) is that project task instead | its hours × 10 × priority × importance | ×0.1 (`alignment.task_area`) to its own `@area(...)` |

An md objective (30 hours, 300 XP) finished through its key results earns
300 for the work, 60 for its key results and 60 when you mark it done: 420
Mastery XP. The same 30 hours on projects with only an `@area` earn 60.

**Which areas.** An award's Mastery share is split over its areas, first
listed first, each getting `xp.area_split` of the one before (0.5 by
default: ½, ¼, …; 1 splits evenly, 0.7 decays gently):

- work on a project a key result links: the objectives' areas, then the
  project's own (or inherited) `@area`, then the task's;
- other work: the task's own `@area`, then the project's.

**Task groups.** Tasks nested under a task make it a group, and the group's
`@size` is shared by them:

```
- [ ] Security audit @size(md)           the group: 1h in all
    - [./z/generated/audit.md]           not a task: doesn't count
    - [ ] Cloudflare tunnel              15m (an equal share: all unsized)
    - [ ] Cloudflare cert                15m
    - [ ] Wi-Fi password @size(lg)       or, sized: in proportion to the sizes,
    - [ ] SSH host key                   the group's size still the total
```

Sized tasks share in proportion to their sizes (unsized ones count as md, a
sub-group as its own total), so the group's size wins either way; a group
without `@size` is the sum of its tasks. The group adds nothing of its own:
progress, project pools and XP count its tasks, each paid its share (with the
group's priority and importance when it has none of its own). Checking the
group checks its open tasks, checking its last open task checks it, and
reopening a task reopens the groups above it; reopening the group leaves its
tasks as they are. The planner offers the group, not its tasks ("4 of 6 tasks
open"), and its calendar copy weighs what is left of it: tick the tasks in
the note (follow the copy's link). Indentation makes the group, through other
lines (a label or a link between them is fine); a heading ends it.

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
a project re-spreads the same pool over more tasks. A task group's tasks are
tasks of the project here: the group's size is what they add to the pool, and
the curve pays them in the order they are done (outside a project, each task
is paid its share).

**Dates.** Toggling a task adds `@done(today)`. A task checked by hand gets
`@done(today)` when the note is saved, if it was newly checked in that edit
(`xp.stamp_done_on_save`). Completions without a date count for Mastery but
not for the reviews.

### Read off the notes

Nothing is recorded when you check a task: `services/xp/ledger` rebuilds
every award from the notes whenever one changes. Unchecking, archiving, or
editing a note on your phone simply changes the result. Only seasons (their
names, spans and dates, and the final progress and tier of past ones) and
the levels and tier last announced are stored. Nothing to drift: no
running totals to double count, keep after unchecking or miss from another
device.

## Using it

| command | |
|---|---|
| `:ZortexPlan` (`<leader>zm`) | plan a day |
| `:ZortexReview day` / `:ZortexReview` | daily / weekly review |
| `:ZortexXPGuide` (`<leader>zxg`) | how XP is calibrated: hours per `@size`, Mastery, tiers; and what the line at the cursor is worth |
| `:ZortexXP` (`<leader>zxx`) | one view: the season's objectives and tier, XP per day for two weeks and how much of that work went to key results, areas only or neither, projects in progress, recent awards, the area tree (`<CR>` opens a line's source, `e` explains a project, `g` the guide) |
| `:ZortexXPExplain` (`<leader>zxe`) | how the project at the cursor earned its XP, award by award |
| `:ZortexSeason start [span] [name]` / `end` / `status` | a season of your own instead of the quarter (`start 6M-2026-H2`; without a span it asks, the quarter filled in); `start` adds its heading to `okr.zortex` |

On the web, the home page of `zortex serve` shows the season (progress,
tier, its objectives), Mastery XP per day for two weeks, top areas and recent
awards. Tasks completed on the web are listed as pending, with the XP they
are estimated to earn (hours × XP per hour × priority × importance, from
the calibration in the summary), until Neovim counts them. Neovim
publishes that summary after every change (`.z/xp_summary.<device>.json`, and
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

`Config.xp` (see `lua/zortex/config.lua`): `enabled` (false: no XP,
Mastery, seasons or tiers in Neovim, and their commands and keys go;
`@size` still weighs progress; the server's `-xp=false` hides them on the
web), `xp_per_hour`,
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
