-- ui/telescope/search.lua - Search UI using DocumentManager-based search service
local M = {}

local SearchService = require("zortex.services.search")
local EventBus = require("zortex.core.event_bus")
local fs = require("zortex.utils.filesystem")
local Config = require("zortex.config")

-- =============================================================================
-- Search History (UI State)
-- =============================================================================

local SearchHistory = {
	entries = {},
	max_entries = 50,
}

function SearchHistory.add(query, selected_result)
	table.insert(SearchHistory.entries, 1, {
		timestamp = os.time(),
		query = query,
		selected_file = selected_result and selected_result.filepath,
		selected_section = selected_result and selected_result.section.text,
	})

	-- Limit history size
	while #SearchHistory.entries > SearchHistory.max_entries do
		table.remove(SearchHistory.entries)
	end

	-- Emit event
	EventBus.emit("search:history_updated", {
		query = query,
		result = selected_result,
	})
end

-- =============================================================================
-- Telescope Integration
-- =============================================================================

-- Create custom previewer
local function create_zortex_previewer()
	local previewers = require("telescope.previewers")
	local highlights = require("zortex.features.highlights")

	return previewers.new_buffer_previewer({
		title = "Zortex Preview",

		define_preview = function(self, entry, status)
			if not entry or not entry.value then
				return
			end

			local result = entry.value

			-- Read file content
			local lines = fs.read_lines(result.filepath)
			if not lines then
				return
			end

			-- Set buffer content
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

			-- Apply Zortex highlighting
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(self.state.bufnr) then
					highlights.highlight_buffer(self.state.bufnr)

					-- Highlight the target line
					if result.section and result.section.start_line then
						local ns_id = vim.api.nvim_create_namespace("zortex_search_highlight")
						vim.api.nvim_buf_add_highlight(
							self.state.bufnr,
							ns_id,
							"CursorLine",
							result.section.start_line - 1,
							0,
							-1
						)

						-- Scroll to the target line
						vim.api.nvim_win_call(status.preview_win, function()
							vim.fn.cursor(result.section.start_line, 1)
							vim.cmd("normal! zz")
						end)
					end
				end
			end)
		end,

		get_buffer_by_name = function(_, entry)
			return entry.value.filepath
		end,
	})
end

-- Format display for telescope entry
local function format_telescope_display(result)
	local entry_display = require("telescope.pickers.entry_display")

	-- Build display components
	local items = {}

	-- Add breadcrumb components with proper highlighting
	local breadcrumb_parts = vim.split(result.breadcrumb, " > ")
	for i, part in ipairs(breadcrumb_parts) do
		local hl_group = "Normal"

		-- Determine highlight based on position/type
		if i == 1 then
			hl_group = "Title" -- Article
		elseif i == #breadcrumb_parts then
			hl_group = "Function" -- Current section
		else
			hl_group = "Comment" -- Parent sections
		end

		table.insert(items, { part, hl_group })

		if i < #breadcrumb_parts then
			table.insert(items, { " > ", "NonText" })
		end
	end

	-- Add file indicator if needed
	if result.source == "buffer" then
		table.insert(items, { " [*]", "DiagnosticHint" })
	end

	-- Create displayer
	local displayer = entry_display.create({
		separator = "",
		items = items,
	})

	return displayer(items)
end

-- Create new note
local function create_new_note(prompt_bufnr)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)

	-- Generate unique filename
	local date = os.date("%Y-%m-%d")
	local ext = Config.extension

	math.randomseed(os.time())
	local filename
	for i = 1, 1000 do
		local num = string.format("%03d", math.random(0, 999))
		filename = date .. "." .. num .. ext
		local filepath = fs.get_file_path(filename)

		if filepath and not fs.file_exists(filepath) then
			-- Create and open file
			vim.cmd("edit " .. filepath)
			vim.defer_fn(function()
				vim.api.nvim_buf_set_lines(0, 0, 0, false, { "@@" })
				vim.api.nvim_win_set_cursor(0, { 1, 2 })
				vim.cmd("startinsert")
			end, 100)
			return
		end
	end

	vim.notify("Failed to create unique filename", vim.log.levels.ERROR)
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(opts)
	opts = opts or {}
	opts.search_mode = opts.search_mode or SearchService.modes.SECTION

	local telescope = require("telescope")
	local pickers = require("telescope.pickers")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values

	-- Track current query for history
	local current_query = ""

	-- Create finder using search service
	local finder = SearchService.create_telescope_finder(opts)

	-- Create custom entry maker
	finder._entry_maker = finder.entry_maker
	finder.entry_maker = function(result)
		local entry = finder._entry_maker(result)

		-- Add custom display
		entry.display = function()
			return format_telescope_display(result)
		end

		return entry
	end

	-- Track query changes
	local original_new_table = finder.new_table
	finder.new_table = function(_, prompt)
		current_query = prompt
		return original_new_table(finder, prompt)
	end

	-- Create previewer
	local previewer = create_zortex_previewer()

	-- Determine prompt title
	local prompt_title = "Zortex Search"
	if opts.search_mode == SearchService.modes.SECTION then
		prompt_title = "Zortex Section Search"
	elseif opts.search_mode == SearchService.modes.ARTICLE then
		prompt_title = "Zortex Article Search"
	elseif opts.search_mode == SearchService.modes.TASK then
		prompt_title = "Zortex Task Search"
	end

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = prompt_title,
			finder = finder,
			sorter = conf.generic_sorter(opts),
			previewer = previewer,
			layout_strategy = "flex",
			layout_config = {
				flex = { flip_columns = 120 },
				horizontal = { preview_width = 0.60 },
				vertical = { preview_height = 0.40 },
			},
			attach_mappings = function(bufnr, map)
				-- Default action
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						-- Save to history
						SearchHistory.add(current_query, selection.value)

						-- Close telescope
						actions.close(bufnr)

						-- Open result
						SearchService.open_result(selection.value)
					end
				end)

				-- Create new note
				map({ "i", "n" }, "<C-o>", function()
					create_new_note(bufnr)
				end)

				-- Clear prompt
				map("i", "<C-u>", function()
					vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
				end)

				-- Open in split
				map({ "i", "n" }, "<C-x>", function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						SearchHistory.add(current_query, selection.value)
						actions.close(bufnr)
						SearchService.open_result(selection.value, "split")
					end
				end)

				-- Open in vsplit
				map({ "i", "n" }, "<C-v>", function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						SearchHistory.add(current_query, selection.value)
						actions.close(bufnr)
						SearchService.open_result(selection.value, "vsplit")
					end
				end)

				-- Refresh cache
				map({ "i", "n" }, "<C-r>", function()
					SearchService.refresh_all()
					vim.notify("Search cache refreshed", vim.log.levels.INFO)
				end)

				-- Show search stats
				map({ "i", "n" }, "<C-s>", function()
					local stats = SearchService.get_stats()
					vim.notify(vim.inspect(stats), vim.log.levels.INFO)
				end)

				-- Scroll preview
				map({ "i", "n" }, "<C-f>", function()
					actions.preview_scrolling_down(bufnr)
				end)

				map({ "i", "n" }, "<C-b>", function()
					actions.preview_scrolling_up(bufnr)
				end)

				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Search Variants
-- =============================================================================

function M.search_sections(opts)
	opts = opts or {}
	opts.search_mode = SearchService.modes.SECTION
	M.search(opts)
end

function M.search_articles(opts)
	opts = opts or {}
	opts.search_mode = SearchService.modes.ARTICLE
	M.search(opts)
end

function M.search_tasks(opts)
	opts = opts or {}
	opts.search_mode = SearchService.modes.TASK
	M.search(opts)
end

function M.search_all(opts)
	opts = opts or {}
	opts.search_mode = SearchService.modes.ALL
	M.search(opts)
end

-- =============================================================================
-- Quick Search Functions
-- =============================================================================

-- Search for current word
function M.search_current_word()
	local word = vim.fn.expand("<cword>")
	if word and word ~= "" then
		M.search({
			default_text = word,
			search_mode = SearchService.modes.SECTION,
		})
	end
end

-- Search in current file only
function M.search_current_file()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	if filepath == "" then
		vim.notify("Current buffer has no file", vim.log.levels.WARN)
		return
	end

	-- This would need SearchService extension to support file filtering
	vim.notify("Search in current file not yet implemented", vim.log.levels.INFO)
end

-- =============================================================================
-- History Functions
-- =============================================================================

-- Show search history
function M.show_history()
	local lines = { "Recent Searches:" }

	for i, entry in ipairs(SearchHistory.entries) do
		if i > 20 then
			break
		end

		local time_str = os.date("%Y-%m-%d %H:%M", entry.timestamp)
		local line = string.format("%s - %s", time_str, entry.query or "(empty)")

		if entry.selected_file then
			line = line .. " → " .. vim.fn.fnamemodify(entry.selected_file, ":t")
		end

		table.insert(lines, line)
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Clear search history
function M.clear_history()
	SearchHistory.entries = {}
	vim.notify("Search history cleared", vim.log.levels.INFO)
end

return M
