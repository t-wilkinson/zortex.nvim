-- tests/autosize_cases.lua - calendar tasks sized by their block
-- (services/tasks.calendar_size; app/edit CalendarSize). Each case marks
-- line `lnum` (already ticked) and expects the size it gets, or nil.
local day = "2026-10-16:"
return {
	{
		name = "one task until the next timed line: an hour is md",
		lines = { day, "16:00 Report", "  - [x] Task 1", "17:00 Next", "  - [ ] Task 2" },
		lnum = 3,
		size = "md",
	},
	{
		name = "its own range",
		lines = { day, "09:00 - 11:00 Deep work", "  - [x] Write", "09:30 Coffee" },
		lnum = 3,
		size = "lg",
	},
	{
		name = "closest by ratio: 45 minutes is md, 25 is sm",
		lines = { day, "10:00 A", "  - [x] a", "10:45 B", "  - [x] b", "11:10 C" },
		lnum = 3,
		size = "md",
	},
	{
		name = "closest by ratio (second block)",
		lines = { day, "10:00 A", "  - [x] a", "10:45 B", "  - [x] b", "11:10 C" },
		lnum = 5,
		size = "sm",
	},
	{
		name = "a long block: 4 hours, as near 3 as 5: the larger",
		lines = { day, "08:00 Build", "  - [x] Shelves", "12:00 Lunch" },
		lnum = 3,
		size = "2xl",
	},
	{
		name = "two tasks in the block: no size",
		lines = { day, "16:00 Report", "  - [x] Task 1", "  - [ ] Task 2", "17:00 Next" },
		lnum = 3,
	},
	{
		name = "a nested task is a group: no size",
		lines = { day, "16:00 Report", "  - [x] Task 1", "    - [ ] Step", "17:00 Next" },
		lnum = 3,
	},
	{
		name = "already sized",
		lines = { day, "16:00 Report", "  - [x] Task 1 @lg", "17:00 Next" },
		lnum = 3,
	},
	{
		name = "already sized (@size)",
		lines = { day, "16:00 Report", "  - [x] Task 1 @size(xs)", "17:00 Next" },
		lnum = 3,
	},
	{
		name = "the day's last block has no end",
		lines = { day, "16:00 Report", "  - [x] Task 1", "", "2026-10-17:", "09:00 Next" },
		lnum = 3,
	},
	{
		name = "not done",
		lines = { day, "16:00 Report", "  - [ ] Task 1", "17:00 Next" },
		lnum = 3,
	},
	{
		name = "not under a timed line",
		lines = { day, "- [x] Loose", "17:00 Next" },
		lnum = 2,
	},
	{
		name = "notes and references don't count, blank lines are skipped",
		lines = { day, "14:00 Shelves", "  - measure first", "", "  - [x] Buy brackets", "14:30 Next" },
		lnum = 5,
		size = "sm",
	},
	{
		name = "a timed task sizes itself: until the next timed line",
		lines = { day, "16:00 [x] Task 1", "17:00 Next" },
		lnum = 2,
		size = "md",
	},
	{
		name = "a timed task with its own range",
		lines = { day, "09:00 - 11:00 [x] Deep work", "09:30 Coffee" },
		lnum = 2,
		size = "lg",
	},
	{
		name = "the dashed form",
		lines = { day, "16:00 - [x] Task 1", "16:30 Next" },
		lnum = 2,
		size = "sm",
	},
	{
		name = "a timed task with tasks under it is a group: no size",
		lines = { day, "16:00 [x] Report", "  - [x] Draft", "17:00 Next" },
		lnum = 2,
	},
}
