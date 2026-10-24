-- features/toc.lua - Table of Contents for Zortex documents
local M = {}

local constants = require("zortex.constants")

-- --- Helper: Parses buffer and builds the TOC text and line mappings
local function get_toc_data(orig_buf)
	local doc = require("zortex.core.document").from_buffer(orig_buf)
	local root_section = doc and doc.tree
	if not root_section or #doc.lines == 0 then
		return nil, nil, "Buffer is empty"
	end

	local toc_lines = {}
	local toc_mappings = {} -- Maps TOC row (1-indexed) to original buffer lnum

	local valid_types = {
		[constants.SECTION_TYPE.HEADING] = true,
		[constants.SECTION_TYPE.BOLD_HEADING] = true,
		[constants.SECTION_TYPE.LABEL] = true,
	}

	local function traverse(sec, depth)
		local added = false
		if valid_types[sec.type] then
			local indent = string.rep("  ", depth)
			local display_text
			if sec.type == constants.SECTION_TYPE.HEADING then
				display_text = indent .. "[" .. string.rep("#", sec.level or 1) .. " " .. sec.text .. "]"
			elseif sec.type == constants.SECTION_TYPE.BOLD_HEADING then
				display_text = indent .. "[**" .. sec.text .. "**:]"
			else -- LABEL
				display_text = indent .. "[" .. sec.text .. ":]"
			end
			table.insert(toc_lines, display_text)
			toc_mappings[#toc_lines] = sec.start_line
			added = true
		end

		-- Headings under an article start at indent 0; the synthetic root and
		-- article nodes don't consume an indent level.
		local next_depth = added and (depth + 1) or depth
		if sec.type == constants.SECTION_TYPE.ARTICLE or sec.type == "root" then
			next_depth = 0
		end

		for _, child in ipairs(sec.children) do
			traverse(child, next_depth)
		end
	end

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

-- --- Helper: Applies window settings and local keymaps. `view` is the
-- TOC's state ({ orig_win, orig_buf, mappings }), which live() keeps current.
local function setup_toc_window(toc_win, toc_buf, view)
	-- Window local options for a clean UI
	vim.wo[toc_win].wrap = false
	vim.wo[toc_win].number = false
	vim.wo[toc_win].relativenumber = false
	vim.wo[toc_win].signcolumn = "no"
	vim.wo[toc_win].cursorline = true
	vim.wo[toc_win].conceallevel = 2 -- Ensures the Link bracket conceals trigger correctly

	-- the keys: zortex.keys ("toc")
	require("zortex.keys").map(toc_buf, "toc", {
		jump = function()
			local cursor = vim.api.nvim_win_get_cursor(toc_win)
			local target_lnum = view.mappings[cursor[1]]
			local orig_win, orig_buf = view.orig_win, view.orig_buf
			if target_lnum and vim.api.nvim_win_is_valid(orig_win) and vim.api.nvim_buf_is_valid(orig_buf) then
				vim.api.nvim_set_current_win(orig_win)
				if vim.api.nvim_win_get_buf(orig_win) ~= orig_buf then
					vim.api.nvim_win_set_buf(orig_win, orig_buf)
				end
				-- the target line may have gone since the TOC was made
				local safe_lnum = math.min(target_lnum, vim.api.nvim_buf_line_count(orig_buf))
				vim.api.nvim_win_set_cursor(orig_win, { safe_lnum, 0 })
				vim.cmd("normal! zz")
				-- a popup TOC (it has a zindex) closes after the jump
				if vim.api.nvim_win_get_config(toc_win).zindex then
					pcall(vim.api.nvim_win_close, toc_win, true)
				end
			end
		end,
		close = function()
			pcall(vim.api.nvim_win_close, toc_win, true)
		end,
	})
end

-- The TOC row of the section the source cursor is in: the last mapped line
-- at or above it.
local function row_for(mappings, lnum)
	local best, best_line
	for row, l in pairs(mappings) do
		if l <= lnum and (not best_line or l > best_line) then
			best, best_line = row, l
		end
	end
	return best
end

-- Keep the TOC current: rebuilt (debounced) as its note changes, following
-- the source cursor, and, for the split, following the note shown in the
-- source window. Everything stops when the TOC buffer goes.
local function live(toc_buf, toc_win, view, opts)
	local group = vim.api.nvim_create_augroup("ZortexTOC_" .. toc_buf, { clear = true })
	local timer = vim.uv.new_timer()
	local function set_lines(lines)
		vim.bo[toc_buf].modifiable = true
		vim.bo[toc_buf].readonly = false
		vim.api.nvim_buf_set_lines(toc_buf, 0, -1, false, lines)
		vim.bo[toc_buf].modifiable = false
		vim.bo[toc_buf].readonly = true
	end
	local function follow_cursor()
		if not (vim.api.nvim_win_is_valid(toc_win) and vim.api.nvim_win_is_valid(view.orig_win)) then
			return
		end
		if vim.api.nvim_get_current_win() == toc_win or vim.api.nvim_win_get_buf(view.orig_win) ~= view.orig_buf then
			return
		end
		local row = row_for(view.mappings, vim.api.nvim_win_get_cursor(view.orig_win)[1])
		if row then
			pcall(vim.api.nvim_win_set_cursor, toc_win, { row, 0 })
		end
	end
	local function rebuild()
		if not (vim.api.nvim_buf_is_valid(toc_buf) and vim.api.nvim_buf_is_valid(view.orig_buf)) then
			return
		end
		local lines, mappings = get_toc_data(view.orig_buf)
		view.mappings = mappings or {}
		local row = vim.api.nvim_win_is_valid(toc_win) and vim.api.nvim_win_get_cursor(toc_win)[1] or 1
		set_lines(lines or { "(no headings, bold headings or labels)" })
		if vim.api.nvim_win_is_valid(toc_win) then
			pcall(vim.api.nvim_win_set_cursor, toc_win, { math.min(row, vim.api.nvim_buf_line_count(toc_buf)), 0 })
		end
		follow_cursor()
	end
	local function schedule()
		timer:stop()
		timer:start(150, 0, vim.schedule_wrap(rebuild))
	end
	local function watch(buf)
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
			group = group,
			buffer = buf,
			callback = schedule,
		})
		vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = follow_cursor })
	end
	watch(view.orig_buf)
	if opts and opts.follow_buffer then
		-- the split: another note in the source window becomes the TOC's
		vim.api.nvim_create_autocmd("BufEnter", {
			group = group,
			callback = function(ev)
				local win = vim.api.nvim_get_current_win()
				if win == toc_win or ev.buf == view.orig_buf or vim.bo[ev.buf].filetype ~= "zortex" then
					return
				end
				if vim.api.nvim_win_get_config(win).relative ~= "" then
					return -- a float (a preview, a picker)
				end
				view.orig_win, view.orig_buf = win, ev.buf
				watch(ev.buf)
				local name = vim.api.nvim_buf_get_name(ev.buf)
				pcall(vim.api.nvim_buf_set_name, toc_buf, "Zortex TOC - " .. (name == "" and "unnamed" or vim.fn.fnamemodify(name, ":t")))
				rebuild()
			end,
		})
	end
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = group,
		buffer = toc_buf,
		once = true,
		callback = function()
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})
	follow_cursor()
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Shows the Table of Contents in a vertical split on the left; it follows
-- the note as you edit it, and the note shown in the window you came from
function M.show_toc()
	local orig_win = vim.api.nvim_get_current_win()
	local orig_buf = vim.api.nvim_get_current_buf()

	local toc_lines, toc_mappings, err = get_toc_data(orig_buf)
	if err then
		vim.notify(err, vim.log.levels.INFO)
		return
	end

	local toc_buf = setup_toc_buffer(orig_buf, toc_lines)

	-- Open window (vertical split on the left side)
	vim.cmd("topleft 40vsplit")
	local toc_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(toc_win, toc_buf)

	local view = { orig_win = orig_win, orig_buf = orig_buf, mappings = toc_mappings }
	setup_toc_window(toc_win, toc_buf, view)
	live(toc_buf, toc_win, view, { follow_buffer = true })
	return toc_buf, toc_win
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

	local view = { orig_win = orig_win, orig_buf = orig_buf, mappings = toc_mappings }
	setup_toc_window(toc_win, toc_buf, view)
	-- the popup opens on the section the cursor is in
	local at = row_for(toc_mappings, vim.api.nvim_win_get_cursor(orig_win)[1])
	if at then
		pcall(vim.api.nvim_win_set_cursor, toc_win, { at, 0 })
	end
	return toc_buf, toc_win
end

return M
