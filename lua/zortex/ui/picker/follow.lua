-- ui/picker/follow.lua - Picker for a ">" link that matches several links
--
-- One row per matched link: its title, where it goes and the section it is
-- in; the preview shows the link's line in its note.
--
--   <CR>   open what the link points to (split / vsplit / tab: the picker's own keys)
--   <C-l>  go to the link's line instead (the notes kept under it)
local Picker = require("zortex.ui.picker")

local M = {}

local SPLIT = { split = "split", vsplit = "vsplit", tabedit = "tab split" }

local function pad(s, width)
	local w = vim.fn.strdisplaywidth(s)
	if w > width then
		return vim.fn.strcharpart(s, 0, width - 1) .. "…"
	end
	return s .. string.rep(" ", width - w)
end

---@param entries { title: string, target: string, where: string, result: table }[]
---@param open fun(entry) follow the link
---@param goto_line fun(entry) jump to its line
function M.spec(entries, open, goto_line)
	local title_width = 10
	for _, e in ipairs(entries) do
		title_width = math.max(title_width, math.min(vim.fn.strdisplaywidth(e.title), 50))
	end
	return {
		title = "Follow link",
		items = function()
			return entries
		end,
		text = function(e)
			return e.title .. " " .. e.target .. " " .. e.where
		end,
		format = function(e)
			return {
				{ pad(e.title, title_width) .. "  " },
				{ pad(e.target, 40) .. "  ", "Comment" },
				{ e.where, "Comment" },
			}
		end,
		location = function(e)
			return { file = e.result.file, lnum = e.result.lnum, text = e.title }
		end,
		open = function(e, cmd)
			if SPLIT[cmd] then
				vim.cmd(SPLIT[cmd])
			end
			open(e)
		end,
		preview = function(e)
			local r = e.result
			return { lines = r.doc.lines, lnum = r.lnum, zortex = true, title = vim.fn.fnamemodify(r.file, ":t") }
		end,
		-- the keys: zortex.keys ("follow")
		keys = require("zortex.keys").picker_keys("follow", { goto_line = { close = true, fn = goto_line } }),
	}
end

function M.pick(entries, open, goto_line)
	return Picker.pick(M.spec(entries, open, goto_line))
end

return M
