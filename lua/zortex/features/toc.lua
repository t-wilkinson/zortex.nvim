-- features/toc.lua - Table of Contents for Zortex documents
local M = {}

local parser = require("zortex.utils.parser")
local section = require("zortex.core.section")
local constants = require("zortex.constants")

-- --- Helper: Parses buffer and builds the TOC text and line mappings
local function get_toc_data(orig_buf)
	local lines = vim.api.nvim_buf_get_lines(orig_buf, 0, -1, false)
	if #lines == 0 then
		return nil, nil, "Buffer is empty"
	end

	-- Build the section tree directly using parser and section
	local builder = section.SectionTreeBuilder:new()
	local code_tracker = parser.CodeBlockTracker:new()

	for line_num, line in ipairs(lines) do
		builder:update_current_end(line_num)
		local in_code_block = code_tracker:update(line)

		if not in_code_block then
			local s = section.create_from_line(line, line_num, in_code_block)
			if s then
				builder:add_section(s)
			end
		end
	end

	local root_section = builder:get_tree()

	local toc_lines = {}
	local toc_mappings = {} -- Maps TOC row (1-indexed) to original buffer lnum

	-- Helper to recursively traverse the section tree and build TOC lines
	local function traverse(sec, depth)
		local valid_types = {
			[constants.SECTION_TYPE.HEADING] = true,
			[constants.SECTION_TYPE.BOLD_HEADING] = true,
			[constants.SECTION_TYPE.LABEL] = true,
		}

		local added = false
		if valid_types[sec.type] then
			local indent = string.rep("  ", depth)
			local display_text = ""

			-- Wrap the text in [ ] so features/highlights.lua treats them as Zortex links
			if sec.type == constants.SECTION_TYPE.HEADING then
				display_text = indent .. "[" .. string.rep("#", sec.level or 1) .. " " .. sec.text .. "]"
			elseif sec.type == constants.SECTION_TYPE.BOLD_HEADING then
				display_text = indent .. "[**" .. sec.text .. "**:]"
			elseif sec.type == constants.SECTION_TYPE.LABEL then
				display_text = indent .. "[" .. sec.text .. ":]"
			end

			table.insert(toc_lines, display_text)
			toc_mappings[#toc_lines] = sec.start_line
			added = true
		end

		-- Determine indentation depth for child items
		local next_depth = added and (depth + 1) or depth

		-- The Root article doesn't indent itself, but its immediate children should start at indent 0
		if sec.type == constants.SECTION_TYPE.ARTICLE then
			next_depth = 0
		end

		for _, child in ipairs(sec.children) do
			traverse(child, next_depth)
		end
	end

	-- Start traversal from the document root
	traverse(root_section, 0)

	if #toc_lines == 0 then
		return nil, nil, "No headings, bold headings, or labels found in document."
	end

	return toc_lines, toc_mappings, nil
end

-- --- Helper: Creates the unmodifiable scratch buffer for the TOC
local function setup_toc_buffer(orig_buf, toc_lines)
	local toc_buf = vim.api.nvim_create_buf(false, true)
	local filepath = vim.api.nvim_buf_get_name(orig_buf)
	local filename = filepath == "" and "unnamed" or vim.fn.fnamemodify(filepath, ":t")
	local buf_name = "Zortex TOC - " .. filename

	-- Handle potential buffer name collision safely
	pcall(vim.api.nvim_buf_set_name, toc_buf, buf_name)

	-- Set lines before enabling read-only state
	vim.api.nvim_buf_set_lines(toc_buf, 0, -1, false, toc_lines)

	-- Set buffer options
	vim.bo[toc_buf].filetype = "zortex" -- Enables Zortex syntax highlighting & conceals
	vim.bo[toc_buf].buftype = "nofile"
	vim.bo[toc_buf].swapfile = false
	vim.bo[toc_buf].bufhidden = "wipe"
	vim.bo[toc_buf].modifiable = false
	vim.bo[toc_buf].readonly = true

	return toc_buf
end

-- --- Helper: Applies window settings and local keymaps
local function setup_toc_window(toc_win, toc_buf, orig_win, orig_buf, toc_mappings)
	-- Window local options for a clean UI
	vim.wo[toc_win].wrap = false
	vim.wo[toc_win].number = false
	vim.wo[toc_win].relativenumber = false
	vim.wo[toc_win].signcolumn = "no"
	vim.wo[toc_win].cursorline = true
	vim.wo[toc_win].conceallevel = 2 -- Ensures the Link bracket conceals trigger correctly

	-- Setup keymaps
	local map_opts = { buffer = toc_buf, noremap = true, silent = true }

	-- Jump to section on <CR>
	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(toc_win)
		local row = cursor[1]
		local target_lnum = toc_mappings[row]

		if target_lnum and vim.api.nvim_win_is_valid(orig_win) then
			-- Switch to original window
			vim.api.nvim_set_current_win(orig_win)

			-- Ensure the target line still exists to avoid out-of-bounds errors
			local orig_line_count = vim.api.nvim_buf_line_count(orig_buf)
			local safe_lnum = math.min(target_lnum, orig_line_count)

			-- Move cursor and center screen
			vim.api.nvim_win_set_cursor(orig_win, { safe_lnum, 0 })
			vim.cmd("normal! zz")

			-- If the TOC window is a floating popup (has a zindex), close it after jumping
			local win_config = vim.api.nvim_win_get_config(toc_win)
			if win_config.zindex then
				pcall(vim.api.nvim_win_close, toc_win, true)
			end
		end
	end, vim.tbl_extend("force", map_opts, { desc = "Jump to Zortex Section" }))

	-- Close TOC on 'q' or '<Esc>'
	local function close_toc()
		pcall(vim.api.nvim_win_close, toc_win, true)
	end
	vim.keymap.set("n", "q", close_toc, vim.tbl_extend("force", map_opts, { desc = "Close Zortex TOC" }))
	vim.keymap.set("n", "<Esc>", close_toc, vim.tbl_extend("force", map_opts, { desc = "Close Zortex TOC" }))
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Shows the Table of Contents in a vertical split on the right
function M.show_toc()
	local orig_win = vim.api.nvim_get_current_win()
	local orig_buf = vim.api.nvim_get_current_buf()

	local toc_lines, toc_mappings, err = get_toc_data(orig_buf)
	if err then
		vim.notify(err, vim.log.levels.INFO)
		return
	end

	local toc_buf = setup_toc_buffer(orig_buf, toc_lines)

	-- Open window (vertical split on the right side)
	vim.cmd("botright 40vsplit")
	local toc_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(toc_win, toc_buf)

	setup_toc_window(toc_win, toc_buf, orig_win, orig_buf, toc_mappings)
	vim.notify("Zortex TOC opened. Press <CR> to jump, 'q' to close.", vim.log.levels.INFO)
end

-- Shows the Table of Contents in a floating popup window
function M.show_toc_popup()
	local orig_win = vim.api.nvim_get_current_win()
	local orig_buf = vim.api.nvim_get_current_buf()

	local toc_lines, toc_mappings, err = get_toc_data(orig_buf)
	if err then
		vim.notify(err, vim.log.levels.INFO)
		return
	end

	local toc_buf = setup_toc_buffer(orig_buf, toc_lines)

	-- Calculate popup dimensions (60% width, 80% height of the editor)
	local width = math.floor(vim.o.columns * 0.6)
	local height = math.floor(vim.o.lines * 0.8)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Configure the floating window
	local win_opts = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Zortex TOC ",
		title_pos = "center",
		zindex = 50,
	}

	-- Open floating window
	local toc_win = vim.api.nvim_open_win(toc_buf, true, win_opts)

	setup_toc_window(toc_win, toc_buf, orig_win, orig_buf, toc_mappings)
	-- No notification needed for popups, as they command focus visually immediately
end

return M
