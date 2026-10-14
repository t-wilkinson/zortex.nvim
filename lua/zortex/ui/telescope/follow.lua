-- ui/telescope/follow.lua - Picker for a ">" link that matches several links
--
-- One row per matched link: its title, where it goes and the section it is
-- in; the preview shows the link's line in its note.
--
--   <CR>   open what the link points to
--   <C-l>  go to the link's line instead (the notes kept under it)
local M = {}

local highlights = require("zortex.features.highlights")

---@param entries { title: string, target: string, where: string, result: table }[]
---@param open fun(entry) follow the link
---@param goto_line fun(entry) jump to its line
function M.pick(entries, open, goto_line)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")
	local entry_display = require("telescope.pickers.entry_display")

	local title_width = 10
	for _, e in ipairs(entries) do
		title_width = math.max(title_width, math.min(vim.fn.strdisplaywidth(e.title), 50))
	end
	local displayer = entry_display.create({
		separator = "  ",
		items = { { width = title_width }, { width = 40 }, { remaining = true } },
	})

	pickers
		.new({}, {
			prompt_title = "Follow link",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return {
						value = e,
						ordinal = e.title .. " " .. e.target .. " " .. e.where,
						filename = e.result.file,
						lnum = e.result.lnum,
						display = function()
							return displayer({
								e.title,
								{ e.target, "Comment" },
								{ e.where, "Comment" },
							})
						end,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Link",
				define_preview = function(self, entry, status)
					local r = entry.value.result
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, r.doc.lines)
					pcall(highlights.highlight_buffer, self.state.bufnr)
					local ns = vim.api.nvim_create_namespace("zortex_follow_preview")
					vim.api.nvim_buf_add_highlight(self.state.bufnr, ns, "CursorLine", r.lnum - 1, 0, -1)
					vim.api.nvim_win_call(status.preview_win, function()
						pcall(vim.api.nvim_win_set_cursor, 0, { r.lnum, 0 })
						vim.cmd("normal! zz")
					end)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				local function run(fn)
					return function()
						local selection = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if selection then
							fn(selection.value)
						end
					end
				end
				actions.select_default:replace(run(open))
				map({ "i", "n" }, "<C-l>", run(goto_line))
				return true
			end,
		})
		:find()
end

return M
