-- tests/gen_edits.lua - Write tests/fixtures/edits.json: line edits as the
-- plugin makes them (services/tasks.edit_line). app/edit (zortex serve) is
-- tested against it, so the web app edits lines exactly like Neovim. Also
-- tests/fixtures/carry.json: carrying open tasks forward
-- (services/planner.carry, cases in tests/carry_cases.lua; app/edit Carry).
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
