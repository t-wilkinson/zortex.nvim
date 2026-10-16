-- Task groups (services/task_groups): cases for tests/fixtures/groups.json,
-- written by tests/gen_edits.lua and read by app/edit (groups_test.go).
--
--   groups   lines -> every task's group, hours and state
--   cascade  lines with line `lnum` just checked or reopened -> the edits
--            that follow
local M = {}

M.today = "2026-10-16"

M.groups = {
	{
		name = "the audit: a sized group, unsized tasks, a link line between",
		lines = {
			"- [ ] Security audit @id(DxqoT) @md",
			"    - [./z/generated/nixos-config-security-audit.md]",
			"    - [ ] Cloudflare tunnel @id(HQUY1)",
			"    - [x] Cloudflare cert @done(2026-10-11)",
			"    - [ ] Google app password",
			"    - [ ] Wi-Fi password",
		},
	},
	{
		name = "sizes share in proportion; a label between; unsized groups add up; a heading ends it",
		lines = {
			"# Home",
			"- [ ] Move @lg @p1",
			"  - [ ] Pack @xl",
			"  - [ ] Clean @md @p3",
			"  Notes:",
			"    - [ ] Keys",
			"- [ ] Garden",
			"  - [ ] Weed @size(sm)",
			"  - [ ] Plant",
			"    - [ ] Buy seeds @xs",
			"## Next",
			"  - [ ] Not nested",
			"- [ ] Alone @xl",
		},
	},
	{
		name = "a checked group: its tasks done, dated by it",
		lines = {
			"- [x] Trip @done(2026-10-01) @md",
			"  - [ ] Book",
			"  - [x] Pack @done(2026-09-30)",
			"    - [ ] Socks",
			"- [>] Carried",
			"  - [ ] Under a carried task",
			"```",
			"- [ ] In code",
			"```",
		},
	},
}

M.cascade = {
	{
		name = "checking a group checks its open tasks, deep ones too",
		lnum = 1,
		lines = { "- [x] Audit @md @done(2026-10-16)", "  - [ ] One", "  - [x] Two @done(2026-10-01)", "  - [ ] Three", "    - [ ] Three a" },
	},
	{
		name = "checking the last open task checks the groups above",
		lnum = 4,
		lines = { "- [ ] Outer", "  - [ ] Inner", "    - [x] A @done(2026-10-02)", "    - [x] B @done(2026-10-16)", "  - [x] Other @done(2026-10-03)" },
	},
	{
		name = "checking one of several open tasks changes nothing else",
		lnum = 2,
		lines = { "- [ ] Audit", "  - [x] One @done(2026-10-16)", "  - [ ] Two" },
	},
	{
		name = "reopening a task reopens the groups above",
		lnum = 3,
		lines = { "- [x] Outer @done(2026-10-05)", "  - [x] Inner @done(2026-10-05)", "    - [ ] A", "    - [x] B @done(2026-10-05)" },
	},
	{
		name = "reopening a group leaves its tasks",
		lnum = 1,
		lines = { "- [ ] Audit", "  - [x] One @done(2026-10-01)" },
	},
	{
		name = "a task in no group",
		lnum = 1,
		lines = { "- [x] Alone @done(2026-10-16)", "- [ ] Next" },
	},
}

return M
