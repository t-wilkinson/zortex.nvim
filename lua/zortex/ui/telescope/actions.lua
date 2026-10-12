-- ui/telescope/actions.lua - Shared Telescope selection & quickfix helpers
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")

local M = {}

--- Returns all marked multi-selections, or falls back to the current cursor entry
---@param prompt_bufnr number
---@return table[]
function M.get_selections(prompt_bufnr)
	local picker = action_state.get_current_picker(prompt_bufnr)
	local multi = picker:get_multi_selection()
	if #multi > 0 then
		return multi
	end
	local single = action_state.get_selected_entry()
	return single and { single } or {}
end

--- Populates the Neovim quickfix list with entries
---@param selections table[]
---@param opts? { title?: string, open_qf?: boolean, on_entry?: fun(entry: table) }
function M.send_to_quickfix(selections, opts)
	opts = opts or {}
	local qf_entries = {}

	for _, item in ipairs(selections) do
		if opts.on_entry then
			opts.on_entry(item)
		end
		table.insert(qf_entries, {
			filename = item.filename or (item.value and item.value.filepath),
			lnum = item.lnum or 1,
			col = item.col or 1,
			text = item.text or item.ordinal or "",
		})
	end

	vim.fn.setqflist(qf_entries, "r")
	if opts.title then
		vim.fn.setqflist({}, "a", { title = opts.title })
	end

	if opts.open_qf ~= false then
		vim.cmd("copen")
	end
end

--- Creates a smart opening action handler that delegates to quickfix when multiple items are selected
---@param cmd string "edit" | "split" | "vsplit"
---@param opts { open_entry: fun(entry: table, cmd: string), title?: string|fun():string, on_entry?: fun(entry: table) }
---@return fun(prompt_bufnr: number)
function M.smart_open(cmd, opts)
	return function(prompt_bufnr)
		local selections = M.get_selections(prompt_bufnr)
		actions.close(prompt_bufnr)
		if #selections == 0 then
			return
		end

		local title = type(opts.title) == "function" and opts.title() or opts.title

		if #selections > 1 then
			M.send_to_quickfix(selections, { title = title, open_qf = true, on_entry = opts.on_entry })
			opts.open_entry(selections[1], cmd)
		else
			if opts.on_entry then
				opts.on_entry(selections[1])
			end
			opts.open_entry(selections[1], cmd)
		end
	end
end

return M
