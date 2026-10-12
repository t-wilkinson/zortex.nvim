-- tests/gen_edits.lua - Write tests/fixtures/edits.json: line edits as the
-- plugin makes them (services/tasks.edit_line). app/edit (zortex serve) is
-- tested against it, so the web app edits lines exactly like Neovim.
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
f:write(vim.json.encode({ today = cases.today, id = cases.id, cases = out }))
f:close()
print("wrote " .. path .. " (" .. #out .. " cases)")
