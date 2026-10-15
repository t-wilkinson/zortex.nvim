-- ui/picker/telescope.lua - The picker interface (ui/picker) on telescope.nvim
--
-- <CR> / <C-x> / <C-v> / <C-t> open (edit, split, vsplit, tab); <Tab>
-- selects several; <C-q> sends the selection (or the current row) to the
-- quickfix list. Live lists keep their own order.
local Picker = require("zortex.ui.picker")

local M = {}

function M.pick(spec)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local function display(entry)
		return Picker.render(spec, entry.value)
	end

	local function entry_maker(item, rank)
		local loc = spec.location(item)
		return {
			value = item,
			rank = rank,
			display = display,
			ordinal = spec.query and "" or Picker.text(spec, item),
			filename = loc.file,
			lnum = loc.lnum,
			col = loc.col,
			text = loc.text,
		}
	end

	local function make_finder()
		if spec.query then
			return finders.new_dynamic({
				fn = function(prompt)
					local out = {}
					for i, item in ipairs(spec.query(prompt or "")) do
						out[i] = { item = item, rank = i }
					end
					return out
				end,
				entry_maker = function(r)
					return entry_maker(r.item, r.rank)
				end,
			})
		end
		return finders.new_table({ results = spec.items(), entry_maker = entry_maker })
	end

	local sorter
	if spec.query then
		-- the live list's own order; the fuzzy sorter only highlights
		sorter = require("telescope.sorters").Sorter:new({
			scoring_function = function(_, _, _, entry)
				return entry.rank or math.huge
			end,
			highlighter = conf.generic_sorter({}).highlighter,
		})
	else
		sorter = conf.generic_sorter({})
	end

	local previewer = spec.preview
		and previewers.new_buffer_previewer({
			title = "Preview",
			define_preview = function(self, entry, status)
				Picker.fill_preview(spec, entry.value, self.state.bufnr, status.preview_win)
			end,
		})

	local function selections(prompt_bufnr)
		local picker = action_state.get_current_picker(prompt_bufnr)
		local multi = picker:get_multi_selection()
		local list = #multi > 0 and multi or { action_state.get_selected_entry() }
		local items = {}
		for _, e in ipairs(list) do
			items[#items + 1] = e and e.value or nil
		end
		return items
	end

	pickers
		.new({}, {
			prompt_title = Picker.title(spec),
			default_text = spec.prompt,
			debounce = spec.query and 80 or nil,
			finder = make_finder(),
			sorter = sorter,
			previewer = previewer or nil,
			attach_mappings = function(prompt_bufnr, map)
				local function open(cmd)
					return function()
						local items = selections(prompt_bufnr)
						actions.close(prompt_bufnr)
						Picker.confirm(spec, items, cmd)
					end
				end
				actions.select_default:replace(open("edit"))
				actions.select_horizontal:replace(open("split"))
				actions.select_vertical:replace(open("vsplit"))
				actions.select_tab:replace(open("tabedit"))
				map({ "i", "n" }, "<C-q>", function()
					local items = selections(prompt_bufnr)
					actions.close(prompt_bufnr)
					if #items > 0 then
						Picker.quickfix(spec, items)
					end
				end)

				local function ctx()
					local picker = action_state.get_current_picker(prompt_bufnr)
					return {
						prompt = picker:_get_prompt(),
						refresh = function()
							picker.prompt_border:change_title(Picker.title(spec))
							picker:refresh(make_finder(), { reset_prompt = false })
						end,
					}
				end
				for _, k in ipairs(Picker.keys(spec)) do
					map({ "i", "n" }, k.lhs, function()
						local entry = action_state.get_selected_entry()
						local c = ctx()
						if k.key.close then
							actions.close(prompt_bufnr)
							c.refresh = nil
						end
						Picker.run_key(k.key, entry and entry.value, c)
					end, { desc = k.key.desc })
				end
				return true
			end,
		})
		:find()
end

return M
