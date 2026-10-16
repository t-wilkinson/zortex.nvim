-- tests/gen_edits.lua - Write tests/fixtures/edits.json: line edits as the
-- plugin makes them (services/tasks.edit_line). app/edit (zortex serve) is
-- tested against it, so the web app edits lines exactly like Neovim. Also
-- tests/fixtures/carry.json: carrying open tasks forward
-- (services/planner.carry, cases in tests/carry_cases.lua; app/edit Carry),
-- and tests/fixtures/groups.json: task groups (services/task_groups, cases
-- in tests/group_cases.lua; app/edit Groups, Cascade).
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
