-- ui/telescope/search.lua - Search UI using independent document loading
local M = {}

local SearchService = require("zortex.services.search")
local EventBus = require("zortex.core.event_bus")
local fs = require("zortex.utils.filesystem")
local highlights = require("zortex.features.highlights")
local Config = require("zortex.config")

-- =============================================================================
-- Custom Sorter with Smart Scoring
-- =============================================================================

local function create_smart_sorter()
	local sorters = require("telescope.sorters")

	return sorters.Sorter:new({
		scoring_function = function(_, prompt, entry)
			-- Entry already has a pre-calculated score from search service
			if entry and entry.score then
				-- Lower scores rank higher in Telescope
				return 1000 / (entry.score + 1)
			end
			return 999999
		end,

		-- Disable highlighting since we handle it ourselves
		highlighter = function()
			return {}
		end,
	})
end

-- =============================================================================
-- Breadcrumb Display with Highlights
-- =============================================================================

local function format_breadcrumb_display(breadcrumb)
	if not breadcrumb or breadcrumb == "" then
		return "Untitled"
	end

	-- Split breadcrumb by separator
	local parts = {}
	local current_pos = 1
	local sep = " › "

	while true do
		local sep_start, sep_end = breadcrumb:find(sep, current_pos, true)
		if not sep_start then
			-- Last part
			local part = breadcrumb:sub(current_pos)
			if part ~= "" then
				table.insert(parts, part)
			end
			break
		else
			-- Part before separator
			local part = breadcrumb:sub(current_pos, sep_start - 1)
			if part ~= "" then
				table.insert(parts, part)
			end
			current_pos = sep_end + 1
		end
	end

	-- Build display with highlights
	local display_parts = {}
	for i, part in ipairs(parts) do
		if i > 1 then
			table.insert(display_parts, { sep, "Comment" })
		end

		-- Determine highlight based on position (simplified)
		local hl_group = "Normal"
		if i == 1 then
			hl_group = "Title" -- Article
		elseif i == #parts then
			hl_group = "Function" -- Target section
		else
			hl_group = "Type" -- Intermediate sections
		end

		table.insert(display_parts, { part, hl_group })
	end

	return display_parts
end

-- =============================================================================
-- Enhanced Previewer
-- =============================================================================

local function create_zortex_previewer()
	local previewers = require("telescope.previewers")

	return previewers.new_buffer_previewer({
		title = "Zortex Preview",

		define_preview = function(self, entry, status)
			if not entry or not entry.value then
				return
			end

			local result = entry.value
			local lines = fs.read_lines(result.filepath)
			if not lines then
				return
			end

			-- Set buffer content
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

			-- Apply highlighting and scroll to position
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(self.state.bufnr) then
					-- Apply Zortex syntax highlighting
					highlights.highlight_buffer(self.state.bufnr)

					-- Highlight the target section
					if result.section and result.section.start_line then
						local ns_id = vim.api.nvim_create_namespace("zortex_search_highlight")

						-- Highlight the entire section
						local end_line = result.section.end_line or result.section.start_line
						for line = result.section.start_line - 1, end_line - 1 do
							if line < #lines then
								vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "Visual", line, 0, -1)
							end
						end

						-- Extra highlight for the section header
						vim.api.nvim_buf_add_highlight(
							self.state.bufnr,
							ns_id,
							"CursorLine",
							result.section.start_line - 1,
							0,
							-1
						)

						-- Scroll to show the section
						vim.api.nvim_win_call(status.preview_win, function()
							vim.fn.cursor(result.section.start_line, 1)
							vim.cmd("normal! zz")
						end)
					end
				end
			end)
		end,

		get_buffer_by_name = function(_, entry)
			return entry.value and entry.value.filepath
		end,
	})
end

-- =============================================================================
-- Note Creation
-- =============================================================================

local function create_new_note(prompt_bufnr, initial_text)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)

	-- Generate unique filename
	local date = os.date("%Y-%m-%d")
	local ext = Config.extension
	math.randomseed(os.time() + os.clock() * 1000)

	for _ = 1, 1000 do
		local filename = string.format("%s.%03d%s", date, math.random(0, 999), ext)
		local filepath = fs.get_file_path(filename)

		if filepath and not fs.file_exists(filepath) then
			vim.cmd("edit " .. vim.fn.fnameescape(filepath))
			vim.defer_fn(function()
				-- Set initial content
				local lines = { "@@" }
				if initial_text and initial_text ~= "" then
					table.insert(lines, "")
					table.insert(lines, initial_text)
				end

				vim.api.nvim_buf_set_lines(0, 0, 0, false, lines)
				vim.api.nvim_win_set_cursor(0, { 1, 2 })
				vim.cmd("startinsert!")
			end, 50)
			return
		end
	end

	vim.notify("Failed to create unique filename", vim.log.levels.ERROR)
end

-- =============================================================================
-- Entry Display
-- =============================================================================

local function make_display(entry)
	if not entry or not entry.value then
		return ""
	end

	local result = entry.value
	local breadcrumb = result.breadcrumb or ""

	-- For empty breadcrumb, show filename
	if breadcrumb == "" then
		breadcrumb = vim.fn.fnamemodify(result.filepath, ":t:r")
	end

	-- Add file indicator if not current buffer
	local current_buf = vim.api.nvim_get_current_buf()
	local current_file = vim.api.nvim_buf_get_name(current_buf)

	if result.filepath ~= current_file then
		local filename = vim.fn.fnamemodify(result.filepath, ":t:r")
		breadcrumb = breadcrumb .. " ← " .. filename
	end

	return breadcrumb
end

-- =============================================================================
-- Telescope Finder
-- =============================================================================

function M.create_telescope_finder(opts)
	local finders = require("telescope.finders")
	local entry_display = require("telescope.pickers.entry_display")

	-- Track current query for history
	local current_query = ""

	return finders.new_dynamic({
		fn = function(prompt)
			current_query = prompt
			local results = SearchService.search(prompt, opts)

			-- Store query in entry for history tracking
			for _, result in ipairs(results) do
				result._query = prompt
			end

			return results
		end,

		entry_maker = function(result)
			if not result then
				return nil
			end

			local breadcrumb = result.breadcrumb or ""
			local filepath = result.filepath or ""

			-- Create display string (must be non-empty)
			local display = breadcrumb
			if display == "" then
				display = vim.fn.fnamemodify(filepath, ":t:r")
			end

			-- Build ordinal for fuzzy matching
			local ordinal = breadcrumb .. " " .. filepath
			if result.section and result.section.text then
				ordinal = ordinal .. " " .. result.section.text
			end

			return {
				value = result,
				ordinal = ordinal,
				display = display,
				filename = filepath,
				lnum = result.section and result.section.start_line or 1,
				col = 1,
				score = result.score, -- Pass through for sorter
			}
		end,
	})
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(opts)
	opts = opts or {}
	opts.search_mode = opts.search_mode or SearchService.modes.SECTION

	local pickers = require("telescope.pickers")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values

	-- Determine prompt title
	local prompt_title = "Zortex Search"
	if opts.search_mode == SearchService.modes.ARTICLE then
		prompt_title = "Zortex Article Search"
	elseif opts.search_mode == SearchService.modes.TASK then
		prompt_title = "Zortex Task Search"
	elseif opts.search_mode == SearchService.modes.ALL then
		prompt_title = "Zortex All Search"
	else
		prompt_title = "Zortex Section Search"
	end

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = prompt_title,
			finder = M.create_telescope_finder(opts),
			sorter = create_smart_sorter(),
			previewer = create_zortex_previewer(),
			layout_strategy = "flex",
			layout_config = {
				flex = { flip_columns = 120 },
				horizontal = { preview_width = 0.6 },
				vertical = { preview_height = 0.4 },
			},
			attach_mappings = function(bufnr, map)
				-- Default action - open and track
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value then
						local result = selection.value

						-- Add to search history
						if result._query and result.section_path then
							SearchService.SearchHistory.add({
								tokens = vim.split(result._query, "%s+"),
								selected_file = result.filepath,
								selected_section = result.section and result.section.start_line,
								section_path = result.section_path,
							})
						end

						actions.close(bufnr)
						SearchService.open_result(result)
					end
				end)

				-- Open in split/vsplit
				local function open_in(cmd)
					return function()
						local selection = action_state.get_selected_entry()
						if selection and selection.value then
							local result = selection.value

							-- Add to search history
							if result._query and result.section_path then
								SearchService.SearchHistory.add({
									tokens = vim.split(result._query, "%s+"),
									selected_file = result.filepath,
									selected_section = result.section and result.section.start_line,
									section_path = result.section_path,
								})
							end

							actions.close(bufnr)
							SearchService.open_result(result, cmd)
						end
					end
				end

				-- Create new note with current query
				map({ "i", "n" }, "<C-o>", function()
					local current_picker = action_state.get_current_picker(bufnr)
					local prompt = current_picker:_get_prompt()
					create_new_note(bufnr, prompt)
				end)

				-- Open in splits
				map({ "i", "n" }, "<C-x>", open_in("split"))
				map({ "i", "n" }, "<C-v>", open_in("vsplit"))

				-- Refresh cache
				map({ "i", "n" }, "<C-r>", function()
					SearchService.refresh_all()
					vim.notify("Search cache refreshed", vim.log.levels.INFO)
					-- Refresh picker
					local current_picker = action_state.get_current_picker(bufnr)
					current_picker:refresh(M.create_telescope_finder(opts), { reset_prompt = false })
				end)

				-- Show stats
				map({ "i", "n" }, "<C-s>", function()
					local stats = SearchService.get_stats()
					local lines = {
						"Zortex Search Statistics:",
						string.format("  Documents loaded: %d", stats.documents_loaded),
						string.format("  Total sections: %d", stats.total_sections),
						string.format("  Total tasks: %d", stats.total_tasks),
						string.format("  Access history: %d files", stats.access_history_count),
						string.format("  Search history: %d entries", stats.search_history_count),
						string.format("  Search cache: %d documents", stats.cache_documents),
					}
					vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
				end)

				-- Preview scrolling
				map({ "i", "n" }, "<C-f>", actions.preview_scrolling_down)
				map({ "i", "n" }, "<C-b>", actions.preview_scrolling_up)

				-- Clear prompt
				map("i", "<C-u>", function()
					vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
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
	M.search(vim.tbl_extend("force", { search_mode = SearchService.modes.SECTION }, opts or {}))
end

function M.search_articles(opts)
	M.search(vim.tbl_extend("force", { search_mode = SearchService.modes.ARTICLE }, opts or {}))
end

function M.search_tasks(opts)
	M.search(vim.tbl_extend("force", { search_mode = SearchService.modes.TASK }, opts or {}))
end

function M.search_all(opts)
	M.search(vim.tbl_extend("force", { search_mode = SearchService.modes.ALL }, opts or {}))
end

-- =============================================================================
-- Quick Search Functions
-- =============================================================================

function M.search_current_word()
	local word = vim.fn.expand("<cword>")
	if word and word ~= "" then
		M.search_sections({ default_text = word })
	else
		M.search_sections()
	end
end

function M.search_current_section()
	local bufnr = vim.api.nvim_get_current_buf()
	local doc = require("zortex.core.document_manager").get_buffer(bufnr)

	if not doc then
		-- Try to load from search cache if buffer not loaded
		local filepath = vim.api.nvim_buf_get_name(bufnr)
		if filepath and filepath ~= "" then
			local SearchService = require("zortex.services.search")
			-- Force a search to populate cache
			SearchService.search("", { search_mode = SearchService.modes.SECTION })
		else
			vim.notify("No Zortex document loaded", vim.log.levels.WARN)
			return
		end
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

	if doc and doc.get_section_at_line then
		local section = doc:get_section_at_line(cursor_line)
		if section and section.text then
			M.search_sections({ default_text = section.text })
		else
			M.search_sections()
		end
	else
		-- Fallback to simple search
		M.search_sections()
	end
end

-- =============================================================================
-- History UI
-- =============================================================================

function M.show_history()
	local SearchHistory = SearchService.SearchHistory
	if #SearchHistory.entries == 0 then
		vim.notify("No search history", vim.log.levels.INFO)
		return
	end

	local lines = { "Recent Searches:", "" }
	for i, entry in ipairs(SearchHistory.entries) do
		if i > 20 then
			break
		end

		local time_str = os.date("%Y-%m-%d %H:%M", entry.timestamp)
		local query = table.concat(entry.tokens or {}, " ")
		local line = string.format("%d. [%s] %s", i, time_str, query)

		if entry.selected_file then
			local filename = vim.fn.fnamemodify(entry.selected_file, ":t")
			line = line .. " → " .. filename

			if entry.selected_section then
				line = line .. ":" .. entry.selected_section
			end
		end

		table.insert(lines, line)
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	-- Pass options to search service
	SearchService.setup(opts)
end

return M
