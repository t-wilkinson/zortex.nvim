-- ui/picker/select.lua - The picker interface (ui/picker) on vim.ui.select,
-- for when no picker plugin is installed (or one that replaces
-- vim.ui.select, like dressing.nvim). A live list asks for the query first.
-- No preview or extra keys; the choice opens.
local Picker = require("zortex.ui.picker")

local M = {}

function M.pick(spec)
	local function choose(list)
		if #list == 0 then
			vim.notify("Nothing found", vim.log.levels.INFO)
			return
		end
		vim.ui.select(list, {
			prompt = Picker.title(spec),
			format_item = function(item)
				-- columns padded for the other pickers don't line up here
				return (Picker.render(spec, item):gsub("%s%s+", "  "))
			end,
		}, function(item)
			if item then
				Picker.confirm(spec, { item }, "edit")
			end
		end)
	end
	if spec.query then
		vim.ui.input({ prompt = Picker.title(spec) .. ": ", default = spec.prompt }, function(q)
			if q then
				choose(spec.query(q))
			end
		end)
		return
	end
	choose(spec.items())
end

return M
