-- tests/gen_edits.lua - Write tests/fixtures/edits.json: line edits as the
-- plugin makes them (services/tasks.edit_line). app/edit (zortex serve) is
-- tested against it, so the web app edits lines exactly like Neovim. Also
-- tests/fixtures/carry.json: carrying open tasks forward
-- (services/planner.carry, cases in tests/carry_cases.lua; app/edit Carry),
-- tests/fixtures/groups.json: task groups (services/task_groups, cases
-- in tests/group_cases.lua; app/edit Groups, Cascade),
-- tests/fixtures/autosize.json: calendar tasks sized by their block
-- (services/tasks.calendar_size; app/edit CalendarSize), and
-- tests/fixtures/calendar.json: the calendar's entries as Neovim's calendar
-- reads them (stores/calendar; app/web calendarEntries).
--
--   nvim --headless -u NONE -l tests/gen_edits.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local cases = require("edit_cases")
local tasks = require("zortex.services.tasks")
local out = {}
for _, line in ipairs(cases.lines) do
	for _, op in ipairs(cases.ops) do
		local result, err = tasks.edit_line(line, op, { today = cases.today, id = cases.id })
		out[#out + 1] = { line = line, op = op, result = result, error = err and true or nil }
	end
end
local path = root .. "/tests/fixtures/edits.json"
local f = assert(io.open(path, "w"))
f:write(require("json").encode({ today = cases.today, id = cases.id, cases = out }) .. "\n")
f:close()
print("wrote " .. path .. " (" .. #out .. " cases)")

local carry = {}
for _, c in ipairs(require("carry_cases")) do
	local n = 0
	local plan = require("zortex.services.planner").carry(c.lines, c.today, {
		from = c.from,
		new_id = function()
			n = n + 1
			return string.format("C%04d", n)
		end,
	})
	carry[#carry + 1] = {
		name = c.name,
		today = c.today,
		from = c.from,
		lines = c.lines,
		edits = plan.edits,
		inserts = plan.inserts,
	}
end
local carry_path = root .. "/tests/fixtures/carry.json"
f = assert(io.open(carry_path, "w"))
f:write(require("json").encode({ cases = carry }) .. "\n")
f:close()
print("wrote " .. carry_path .. " (" .. #carry .. " cases)")

-- Calendar tasks sized by their block (services/tasks.calendar_size;
-- app/edit autosize.go)
do
	local Config = require("zortex.config")
	local sizes = Config.defaults.xp.sizes.task
	local out_cases = {}
	for _, c in ipairs(require("autosize_cases")) do
		out_cases[#out_cases + 1] = {
			name = c.name,
			lines = c.lines,
			lnum = c.lnum,
			size = tasks.calendar_size(c.lines, c.lnum, sizes) or "",
		}
	end
	local p = root .. "/tests/fixtures/autosize.json"
	local fh = assert(io.open(p, "w"))
	fh:write(require("json").encode({ sizes = sizes, cases = out_cases }) .. "\n")
	fh:close()
	print("wrote " .. p .. " (" .. #out_cases .. " cases)")
end

-- The calendar as Neovim's calendar sees it (stores/calendar), for the web
-- app's calendarDays (app/web calendar_test.go)
do
	local lines = require("calendar_cases")
	local store = require("zortex.stores.calendar")
	local days = {}
	for date, entries in pairs(store.parse_lines(lines)) do
		local rows = {}
		for _, e in ipairs(store.day_layout(entries)) do
			local stop = e:get_end_time()
			rows[#rows + 1] = {
				lnum = e.lnum,
				time = e:get_time_string() or "",
				["end"] = stop and stop.hour and string.format("%02d:%02d", stop.hour, stop.min) or "",
				text = e.text or "",
				task = e.type == "task",
				done = e.completed and true or false,
				moved = e.mark == ">",
				depth = e.depth,
			}
		end
		days[date] = rows
	end
	-- the top of the calendar: a new day's template, and what the repeating
	-- rules put on each day of October 2026
	local rules_mod = require("zortex.services.calendar_rules")
	local templates = {}
	for _, date in ipairs({ "2026-10-11", "2026-10-12", "2026-10-17" }) do
		templates[date] = rules_mod.template(lines, date)
	end
	local CalendarEntry = require("zortex.services.calendar_entry")
	local parsed = store.parse_lines(lines)
	local for_copies = {}
	for _, entries in pairs(parsed) do
		for _, e in ipairs(entries) do
			local d = e.raw_text:match("@for%((%d%d%d%d%-%d%d%-%d%d)%)")
			if d then
				for_copies[d] = for_copies[d] or {}
				for_copies[d][e.text] = e
			end
		end
	end
	local occurrences = {}
	for day = 1, 31 do
		local date = string.format("2026-10-%02d", day)
		local rows = {}
		for _, rule in ipairs(rules_mod.rules(lines)) do
			if rules_mod.matches(rule, date) then
				local e = CalendarEntry.from_text(rules_mod.plain_line(rule.line), date)
				local own = false
				for _, x in ipairs(parsed[date] or {}) do
					if x.text == e.text and not x.raw_text:match("@for%(") then
						own = true
					end
				end
				if not own then
					local copy = (for_copies[date] or {})[e.text]
					local stop = e:get_end_time()
					rows[#rows + 1] = {
						rule = rule.lnum,
						time = e:get_time_string() or "",
						["end"] = stop and stop.hour and string.format("%02d:%02d", stop.hour, stop.min) or "",
						text = rules_mod.label(rule, e.text or "", date),
						task = e.type == "task",
						done = copy and copy.completed and true or false,
						copy = copy and copy.lnum or 0,
					}
				end
			end
		end
		if #rows > 0 then
			occurrences[date] = rows
		end
	end
	local copies = {}
	for _, c in ipairs({ { 22, "2026-10-18", "2026-10-18" }, { 22, "2026-10-11", "2026-10-13" }, { 23, "2026-10-20", "2026-10-20" }, { 29, "2026-10-14", "2026-10-15" } }) do
		local rule = rules_mod.rule(lines[c[1]], c[1])
		copies[#copies + 1] = { lnum = c[1], date = c[2], today = c[3], line = rules_mod.done_copy(rule, c[2], c[3], "rep01") or "" }
	end
	local p = root .. "/tests/fixtures/calendar.json"
	local fh = assert(io.open(p, "w"))
	fh:write(require("json").encode({ lines = lines, days = days, templates = templates, occurrences = occurrences, copies = copies, id = "rep01" }) .. "\n")
	fh:close()
	print("wrote " .. p)
end

-- Task groups (services/task_groups; app/edit groups.go)
local Groups = require("zortex.services.task_groups")
local Document = require("zortex.core.document")
local gcases = require("group_cases")
local calc = require("zortex.services.xp.calculator")
local Config = require("zortex.config")
calc.setup(vim.deepcopy(Config.defaults.xp))
local sizes = Config.defaults.xp.sizes.task
local function date_text(d)
	if type(d) == "table" then
		return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
	end
	return d or ""
end
local function round(x)
	return math.floor(x * 1e6 + 0.5) / 1e6
end
local group_out = {}
for _, c in ipairs(gcases.groups) do
	local doc = Document.from_lines(c.lines)
	local tasks = doc:items(1, #c.lines, { tasks = true })
	tasks = vim.tbl_filter(function(t)
		return t.mark ~= ">" and not doc:in_code(t.lnum)
	end, tasks)
	Groups.annotate(tasks, require("zortex.services.projects.project").group_opts(doc))
	local rows = {}
	for _, t in ipairs(tasks) do
		rows[#rows + 1] = {
			lnum = t.lnum,
			parent = t.parent_task and t.parent_task.lnum or 0,
			leaf = t.leaf,
			hours = round(t.hours),
			done = t.leaf and t.done_effective or false,
			done_date = date_text(t.done_date),
			open_hours = round(t.open_hours),
			open_leaves = t.open_leaves,
			p = t.xp_attrs.p or "",
			i = t.xp_attrs.i or "",
		}
	end
	group_out[#group_out + 1] = { name = c.name, lines = c.lines, tasks = rows }
end
local cascade_out = {}
for _, c in ipairs(gcases.cascade) do
	cascade_out[#cascade_out + 1] = {
		name = c.name,
		lnum = c.lnum,
		lines = c.lines,
		edits = Groups.cascade(c.lines, c.lnum, gcases.today, require("zortex.services.mirrors").set_done),
	}
end
local groups_path = root .. "/tests/fixtures/groups.json"
f = assert(io.open(groups_path, "w"))
f:write(require("json").encode({
	today = gcases.today,
	sizes = sizes,
	default = calc.task_points(nil),
	groups = group_out,
	cascade = cascade_out,
}) .. "\n")
f:close()
print("wrote " .. groups_path .. " (" .. #group_out .. " + " .. #cascade_out .. " cases)")
