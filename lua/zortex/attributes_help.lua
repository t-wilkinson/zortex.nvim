-- attributes_help.lua - What each @attribute means and how it is written
--
-- One table for every place that explains attributes: :Zortex attributes
-- (a float), attribute completion after "@" (each item's documentation),
-- and the web app's help (tests/gen_docs.lua writes it to
-- app/web/static/attributes.json, which the server embeds; test_zr_actions
-- fails when that file is out of date). doc/Syntax.md#attributes is the
-- long form.
--
-- An entry: { key, short?, insert, formats, where, desc }
--   key      the attribute's name ("due")
--   short    other ways to write it ("@a(4.1)" for @area(4.1))
--   insert   what completion inserts ("@due(")
--   formats  how values are written, as examples
--   where    what it goes on: "task", "project", "objective", "calendar", "note", "any"
--   desc     what it does, in a sentence or two
local M = {}

M.GROUPS = {
	{ id = "plan", title = "Planning: tasks, projects, objectives" },
	{ id = "calendar", title = "The calendar" },
	{ id = "notes", title = "Notes and slides" },
}

M.list = {
	-- planning
	{
		key = "size",
		group = "plan",
		short = { "@xs", "@sm", "@md", "@lg", "@xl" },
		insert = "@size(",
		formats = { "@size(sm)", "@sm", "@size(2xl)", "@epic (projects)" },
		where = "task, project, objective",
		desc = "How long it takes: xs 15m, sm 30m, md 1h, lg 2h, xl 3h, 2xl–5xl 5–20h for a task (projects: xs 2h … ultimate 2,500h). Unsized tasks count as md. Weighs progress and XP (10 XP = 1 hour).",
	},
	{
		key = "due",
		group = "plan",
		insert = "@due(",
		formats = { "@due(2026-10-20)" },
		where = "task, project",
		desc = "Due date: the reviews list it as due or overdue, and the planner ranks it higher as it nears.",
	},
	{
		key = "p",
		group = "plan",
		short = { "@p1", "@p2", "@p3" },
		insert = "@p",
		formats = { "@p1", "@p(1)" },
		where = "task, project, objective",
		desc = "Priority, 1 the highest: ranks work in the planner and the projects picker. XP is unchanged unless xp.modifiers says otherwise.",
	},
	{
		key = "i",
		group = "plan",
		short = { "@i1", "@i2", "@i3" },
		insert = "@i",
		formats = { "@i1", "@i(2)" },
		where = "task, project, objective",
		desc = "Importance, 1 the highest: ranks work like @p.",
	},
	{
		key = "area",
		group = "plan",
		short = { "@a(…)" },
		insert = "@a(",
		formats = { "@area(4.1)", "@a(4.1)", "@a(1.2/Fitness)", "@a(4.1, 2.1)" },
		where = "task, project, objective",
		desc = "The area it serves: 4.1 is [A/#4.1], 1.2/Fitness the label Fitness under 1.2. Its XP counts for that area (area XP). Work with none earns for @a(0.1) until the daily review gives it one.",
	},
	{
		key = "project",
		group = "plan",
		insert = "@project(",
		formats = { "@project(1.4)", "@project(1/1.4)", "@project(P/#Kitchen)" },
		where = "inbox line, task",
		desc = "The project a line belongs to (1.4 is [P/#1.4]): m in the daily review, or Move on the web review, puts it there and drops the attribute.",
	},
	{
		key = "done",
		group = "plan",
		insert = "@done(",
		formats = { "@done(2026-10-12)" },
		where = "task, project, objective",
		desc = "When it was finished (added when you tick it). Dates its XP; on a project or objective heading it marks the whole thing done.",
	},
	{
		key = "id",
		group = "plan",
		insert = "@id(",
		formats = { "@id(4Fz9q)" },
		where = "task",
		desc = "A task's id, added for you: lines with the same @id in the calendar and a project are one task (a copy).",
	},
	{
		key = "xp",
		group = "plan",
		insert = "@xp(",
		formats = { "@xp(500)" },
		where = "project, key result, objective",
		desc = "Its XP outright, instead of what its @size or tasks add up to.",
	},
	{
		key = "someday",
		group = "plan",
		insert = "@someday",
		formats = { "@someday" },
		where = "project",
		desc = "Parked on purpose: not listed as stale or unscheduled (z in the weekly review toggles it).",
	},
	{
		key = "dur",
		group = "plan",
		short = { "@90m", "@2h" },
		insert = "@dur(",
		formats = { "@dur(90m)", "@90m", "@2h" },
		where = "task, calendar line",
		desc = "How long it takes: a calendar entry's length, a task's minutes in the planner's capacity.",
	},
	{
		key = "spent",
		group = "plan",
		insert = "@spent(",
		formats = { "@spent(1h25m)" },
		where = "task",
		desc = "Time worked on it, added by the web app's clocks. Shown in the reviews; it doesn't pay XP.",
	},
	-- calendar
	{
		key = "at",
		group = "calendar",
		insert = "@at(",
		formats = { "@at(14:00)" },
		where = "calendar line",
		desc = "The line's time, as 14:00 at the start of the line does (@from(14:00) @to(15:30) for a range).",
	},
	{
		key = "notify",
		group = "calendar",
		short = { "@n(…)" },
		insert = "@n(",
		formats = { "@notify(15)", "@n(0, 30)", "@n(0, end)", "@n(07:30)", "@n(1d)", "@notify", "@n(no)" },
		where = "calendar line",
		desc = "Notify minutes before (several allowed), at the end of a range, at a time of day, or a day before; @notify alone on an untimed line notifies on the day at 09:00; no silences it. Timed lines notify at their time anyway.",
	},
	{
		key = "event",
		group = "calendar",
		insert = "@event",
		formats = { "@event" },
		where = "calendar line",
		desc = "Something you plan around (an appointment, a flight): listed under Coming up and marked on the web's month grid.",
	},
	{
		key = "share",
		group = "calendar",
		insert = "@share",
		formats = { "@share" },
		where = "calendar line",
		desc = "Published in the server's /calendar.ics for other calendars to subscribe to.",
	},
	{
		key = "free",
		group = "calendar",
		insert = "@free",
		formats = { "@free" },
		where = "calendar line",
		desc = "A timed line that doesn't take your time: the planner's capacity doesn't count it as busy.",
	},
	{
		key = "repeat",
		group = "calendar",
		insert = "@repeat(",
		formats = { "@repeat(daily)", "@repeat(weekly)", "@repeat(2w)", "@repeat(monthly)", "@repeat(yearly)" },
		where = "calendar, # Repeating only",
		desc = "How often the entry shows: daily, weekly, monthly, yearly, or every n days/weeks/months/years (2d, 3w, 6m, 2y, counted from @from).",
	},
	{
		key = "on",
		group = "calendar",
		insert = "@on(",
		formats = { "@on(sun)", "@on(mon, wed, fri)", "@on(weekdays)", "@on(15)", "@on(1st)", "@on(2nd tue)", "@on(last fri)", "@on(03-14)" },
		where = "calendar, # Repeating only",
		desc = "Which days a repeating entry lands on; alone it repeats on those days.",
	},
	{
		key = "from",
		group = "calendar",
		insert = "@from(",
		formats = { "@from(2026-10-06)", "@to(2026-12-31)", "@from(07:30) @to(08:15)" },
		where = "calendar line",
		desc = "A range: the first and last day (both included), or a time range on the line.",
	},
	{
		key = "born",
		group = "calendar",
		insert = "@born(",
		formats = { "@born(1990)", "@born(1961-07-02)" },
		where = "calendar, # Repeating only",
		desc = "Shows the age after the entry's text on the day (a birthday).",
	},
	{
		key = "for",
		group = "calendar",
		insert = "@for(",
		formats = { "@for(2026-10-18)" },
		where = "calendar task",
		desc = "A repeating task's copy done on another day: the day it stands for (added for you).",
	},
	-- notes
	{
		key = "fold",
		group = "notes",
		insert = "@fold",
		formats = { "@fold" },
		where = "heading, label, list item",
		desc = "The section starts folded in Neovim each time the note is shown.",
	},
	{
		key = "slides",
		group = "notes",
		insert = "@slides(",
		formats = { "@slides(2)" },
		where = "note header",
		desc = "The heading level that starts a slide when the note is shown as slides.",
	},
	{
		key = "step",
		group = "notes",
		insert = "@step",
		formats = { "@step", "@steps (on a slide's heading)" },
		where = "line, slide heading",
		desc = "Slides: reveal this line (or each item of the slide) one click at a time.",
	},
	{
		key = "tag",
		group = "notes",
		insert = "@",
		formats = { "@rust", "@home", "@ai-model" },
		where = "any line, note header",
		desc = "Any other bare @word is a tag, found by tag searches (@[rust]). In a note's header it tags the note.",
	},
}

--- The entries, each with its group's title.
function M.entries()
	local titles = {}
	for _, g in ipairs(M.GROUPS) do
		titles[g.id] = g.title
	end
	local out = {}
	for _, e in ipairs(M.list) do
		local x = vim.deepcopy(e)
		x.group_title = titles[e.group]
		out[#out + 1] = x
	end
	return out
end

--- What the web app embeds (app/web/static/attributes.json): plain data.
function M.json()
	return vim.json.encode({ groups = M.GROUPS, attributes = M.list })
end

--- A completion item's documentation: formats, then what it does.
function M.documentation(e)
	local lines = { table.concat(e.formats, "  ·  "), "", e.desc, "", "On: " .. e.where }
	if e.short and #e.short > 0 then
		lines[#lines + 1] = "Also: " .. table.concat(e.short, " ")
	end
	return table.concat(lines, "\n")
end

--- The lines of :Zortex attributes, and which are headings.
function M.lines()
	local lines, headings = {}, {}
	local function heading(text)
		if #lines > 0 then
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = text
		headings[#lines] = true
	end
	heading("Attributes: @key(value), or a bare @word")
	lines[#lines + 1] = "  Anywhere on a line, starting a word. Most have a short form (@a for @area)."
	for _, g in ipairs(M.GROUPS) do
		heading(g.title)
		for _, e in ipairs(M.list) do
			if e.group == g.id then
				lines[#lines + 1] = string.format("  %-14s %s", "@" .. e.key, table.concat(e.formats, "  "))
				lines[#lines + 1] = string.format("  %-14s %s", "", e.desc)
				lines[#lines + 1] = string.format("  %-14s on: %s", "", e.where)
			end
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "  Typing @ completes them · doc/Syntax.md#attributes · q close"
	return lines, headings
end

--- :Zortex attributes: the table in a float.
function M.show()
	local lines, headings = M.lines()
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(width + 2, vim.o.columns - 4)
	local height = math.min(#lines, vim.o.lines - 4)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local ns = vim.api.nvim_create_namespace("zortex_attributes_help")
	for lnum in pairs(headings) do
		vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { end_col = #lines[lnum], hl_group = "Title" })
	end
	vim.bo[buf].modifiable = false
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Attributes ",
		title_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end, { buffer = buf, nowait = true, desc = "close" })
	end
	return buf, win
end

return M
