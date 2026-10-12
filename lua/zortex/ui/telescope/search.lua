-- ui/telescope/search.lua - The structural search picker
--
-- Matching and ranking live in services/search (re-exported here, so
-- require("zortex.ui.telescope.search").setup/query_index keep working).
local search = require("zortex.services.search")
local M = setmetatable({}, { __index = search })
local fs = require("zortex.utils.filesystem")
local highlights = require("zortex.features.highlights")
local Config = require("zortex.config")
local shared_actions = require("zortex.ui.telescope.actions")

local function cfg()
	return search.config or search.setup()
end

local function telescope()
	return {
		pickers = require("telescope.pickers"),
		finders = require("telescope.finders"),
		conf = require("telescope.config").values,
		actions = require("telescope.actions"),
		action_state = require("telescope.actions.state"),
		previewers = require("telescope.previewers"),
	}
end

-- ---------------------------------------------------------------------------
-- Highlight helpers
-- ---------------------------------------------------------------------------

-- Maps a section node type to its Zortex highlight group
local function get_hl_group(node)
	local ntype = node.type and tostring(node.type):lower() or ""
	if ntype == "article" then
		return "ZortexArticle"
	end
	if ntype == "heading" then
		return "ZortexHeading" .. math.min(tonumber(node.level) or 1, 3)
	end
	if ntype == "bold_heading" then
		return "ZortexBoldHeading"
	end
	if ntype == "label" then
		return "ZortexLabel"
	end
	return "Normal"
end

-- Maps a raw content line to its Zortex highlight group (mirrors highlights.lua patterns)
local function get_line_hl_group(line)
	if line:match("^%s*%-%s*%[x%]") then
		return "ZortexTaskDone"
	elseif line:match("^%s*%-%s*%[.?%]") then
		return "ZortexTaskText"
	elseif line:match("^%s*%-%s*%w[^:]*:%s") and not line:find("%.%s.-:") then
		return "ZortexLabelListText"
	elseif line:match("^%s*%-%s*%w[^:]*:$") and not line:find("%.%s.-:") then
		return "ZortexLabelList"
	elseif line:match("^%s*%-") then
		local indent = #(line:match("^(%s*)") or "")
		return "ZortexBullet" .. math.min(math.floor(indent / 2) + 1, 4)
	elseif line:match("^%s*%d+%.") then
		return "ZortexNumberList"
	end
	return "Normal"
end

-- ---------------------------------------------------------------------------
-- Display builders
-- ---------------------------------------------------------------------------

local function make_section_display(entry)
	local node = entry.value.node
	local display_str = ""
	local hl_table = {}
	local first = true

	for _, p_node in ipairs(node:get_full_path()) do
		if p_node.type ~= "root" then
			if not first then
				local sep_start = #display_str
				display_str = display_str .. " › "
				table.insert(hl_table, { { sep_start, #display_str }, "Comment" })
			end
			first = false

			local hl_group = get_hl_group(p_node)
			local start_pos = #display_str
			display_str = display_str .. (p_node.text or "Untitled")
			if start_pos < #display_str then
				table.insert(hl_table, { { start_pos, #display_str }, hl_group })
			end
		end
	end

	if entry.value.archived then
		local start = #display_str
		display_str = display_str .. "  (archive)"
		table.insert(hl_table, { { start, #display_str }, "Comment" })
	end

	return display_str, hl_table
end

-- Line result: article name › trimmed line content with semantic highlight
local function make_line_display(entry)
	local result = entry.value
	local display_str = ""
	local hl_table = {}

	if result.article_name then
		display_str = result.article_name
		table.insert(hl_table, { { 0, #display_str }, "ZortexArticle" })
		local sep_start = #display_str
		display_str = display_str .. " › "
		table.insert(hl_table, { { sep_start, #display_str }, "Comment" })
	end

	local text_start = #display_str
	display_str = display_str .. vim.trim(result.line)
	if text_start < #display_str then
		table.insert(hl_table, { { text_start, #display_str }, get_line_hl_group(result.line) })
	end

	return display_str, hl_table
end

-- ---------------------------------------------------------------------------
-- Previewer
-- ---------------------------------------------------------------------------

local function zortex_previewer()
	return telescope().previewers.new_buffer_previewer({
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

			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(self.state.bufnr) then
					highlights.highlight_buffer(self.state.bufnr)

					local ns_id = vim.api.nvim_create_namespace("zortex_search_preview")
					local focus_line -- 0-indexed

					if result.result_type == "section" then
						focus_line = result.node.start_line - 1
						for line = focus_line, result.node.end_line - 1 do
							if line < #lines then
								vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "Visual", line, 0, -1)
							end
						end
					else
						focus_line = result.lnum - 1
					end

					vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "CursorLine", focus_line, 0, -1)

					vim.api.nvim_win_call(status.preview_win, function()
						vim.fn.cursor(focus_line + 1, 1)
						vim.cmd("normal! zz")
					end)
				end
			end)
		end,
	})
end

-- =============================================================================
-- Note Creation
-- =============================================================================

local function create_new_note(prompt_bufnr, initial_text)
	telescope().actions.close(prompt_bufnr)

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
					-- Add the search text as article name
					lines[1] = "@@" .. initial_text
				end

				vim.api.nvim_buf_set_lines(0, 0, 0, false, lines)
				vim.api.nvim_win_set_cursor(0, { 1, 2 + #(initial_text or "") })
				vim.cmd("startinsert!")
			end, 50)
			return
		end
	end

	vim.notify("Failed to create unique filename", vim.log.levels.ERROR)
end

-- ---------------------------------------------------------------------------
-- Main picker
-- ---------------------------------------------------------------------------

function M.structural_search(opts)
	opts = opts or {}
	local t = telescope()
	local pickers, finders, conf, actions, action_state = t.pickers, t.finders, t.conf, t.actions, t.action_state
	local mode = opts.mode or cfg().default_mode or "section"
	local files = search.files()

	-- All disk reads + tree parsing happen ONCE, here. Each keystroke below
	-- only filters this in-memory index.
	local index = M.build_index(files)

	pickers
		.new(opts, {
			prompt_title = "Zortex Structural Search (" .. mode .. ")",
			debounce = 80, -- ms: coalesce rapid keystrokes (telescope picker option)
			finder = finders.new_dynamic({
				fn = function(prompt)
					return M.query_index(index, prompt, { mode = mode })
				end,
				entry_maker = function(entry)
					if entry.result_type == "section" then
						return {
							value = entry,
							display = make_section_display,
							ordinal = entry.breadcrumb,
							filename = entry.filepath,
							lnum = entry.node.start_line,
							text = entry.breadcrumb,
						}
					else
						return {
							value = entry,
							display = make_line_display,
							ordinal = entry.line,
							filename = entry.filepath,
							lnum = entry.lnum,
							text = vim.trim(entry.line),
						}
					end
				end,
			}),
			-- Keep query_index's ranking; borrow the fuzzy sorter's highlighter
			sorter = require("telescope.sorters").Sorter:new({
				scoring_function = function(_, _, _, entry)
					return entry.value.rank or math.huge
				end,
				highlighter = conf.generic_sorter(opts).highlighter,
			}),
			previewer = zortex_previewer(),
			layout_strategy = "horizontal",
			attach_mappings = function(prompt_bufnr, map)
				local history = require("zortex.services.search_history")

				local function open_entry(entry, cmd)
					local res = entry.value
					vim.cmd(cmd .. " " .. vim.fn.fnameescape(res.filepath))
					local lnum = res.result_type == "section" and res.node.start_line or res.lnum
					vim.fn.cursor(lnum, 1)
					vim.cmd("normal! zz")
				end

				local function open_in(cmd)
					return shared_actions.smart_open(cmd, {
						title = function()
							return "Zortex Search (" .. mode .. ")"
						end,
						open_entry = open_entry,
						on_entry = function(entry)
							if entry.value then
								history.record(entry.value)
							end
						end,
					})
				end

				actions.select_default:replace(open_in("edit"))
				map({ "i", "n" }, "<C-x>", open_in("split"))
				map({ "i", "n" }, "<C-v>", open_in("vsplit"))

				-- Send to quickfix directly
				map({ "i", "n" }, "<C-q>", function()
					local selections = shared_actions.get_selections(prompt_bufnr)
					actions.close(prompt_bufnr)
					if #selections > 0 then
						shared_actions.send_to_quickfix(selections, {
							title = "Zortex Search (" .. mode .. ")",
							on_entry = function(entry)
								if entry.value then
									history.record(entry.value)
								end
							end,
						})
					end
				end)

				-- Create new note with current query
				map({ "i", "n" }, "<C-o>", function()
					local current_picker = action_state.get_current_picker(prompt_bufnr)
					local prompt = current_picker:_get_prompt()
					create_new_note(prompt_bufnr, prompt)
				end)

				-- Toggle section / article mode
				map({ "i", "n" }, "<C-t>", function()
					mode = mode == "article" and "section" or "article"
					local picker = action_state.get_current_picker(prompt_bufnr)
					picker.prompt_border:change_title("Zortex Structural Search (" .. mode .. ")")
					picker:refresh(picker.finder, { reset_prompt = false })
				end)

				-- Preview scrolling
				map({ "i", "n" }, "<C-f>", actions.preview_scrolling_down)
				map({ "i", "n" }, "<C-b>", actions.preview_scrolling_up)

				-- Clear prompt
				map("i", "<C-u>", function()
					vim.api.nvim_buf_set_lines(prompt_bufnr, 0, 1, false, { "" })
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
				end)

				return true
			end,
		})
		:find()
end

return M
