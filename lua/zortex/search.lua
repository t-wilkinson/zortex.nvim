-- search.lua – incremental exact‑substring note search
--   • Space separates tokens (logical AND across the entire file).
--   • Use underscore "_" instead of spaces for phrase search (hello_world searches for "hello world").
--   • One entry per note: <modified_date> | <title> | <first match> | <other matches…>.
--   • Preview uses *bat* with Markdown highlighting (falls back if absent).
--   • M.search() is called at the end so you can :luafile % for quick tests.

local M = {}

--------------------------------------------------
-- Config sanity check
--------------------------------------------------
local function check_globals()
	if not vim.g.zortex_notes_dir or not vim.g.zortex_extension then
		vim.notify("Zortex Search: set vim.g.zortex_notes_dir & vim.g.zortex_extension", vim.log.levels.ERROR)
		return false
	end
	if not vim.g.zortex_notes_dir:match("/$") then
		vim.g.zortex_notes_dir = vim.g.zortex_notes_dir .. "/"
	end
	return true
end

--------------------------------------------------
-- Helpers
--------------------------------------------------
local function open_location(entry, cmd)
	cmd = cmd or "edit"
	if entry and entry.filename and entry.lnum then
		vim.cmd(string.format("%s %s", cmd, entry.filename))
		vim.fn.cursor(entry.lnum, 1)
	end
end

local function create_new_note(prompt_bufnr)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)
	local name = os.date("%Y%W%u%H%M%S") .. vim.g.zortex_extension -- YYYYWWDHHMMSS.ext
	local path = vim.g.zortex_notes_dir .. name
	vim.cmd("edit " .. path)
	vim.defer_fn(function()
		vim.api.nvim_buf_set_lines(0, 0, 0, false, { "@@" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("startinsert")
	end, 100)
end

-- Format timestamp for display
local function format_timestamp(timestamp)
	return os.date("%Y-%m-%d %H:%M", timestamp)
end

-- Extract header name (remove @@ prefix and trim)
local function extract_header_name(title)
	if title:match("^@@") then
		return title:sub(3):gsub("^%s+", ""):gsub("%s+$", "")
	end
	return title
end

--------------------------------------------------
-- File cache (avoids disk I/O on every keystroke)
--------------------------------------------------
local file_cache = {} -- [path] = { mtime, lines }
local function update_file_cache()
	if not check_globals() then
		return
	end
	local dir, ext, uv = vim.g.zortex_notes_dir, vim.g.zortex_extension, vim.loop
	local handle = uv.fs_scandir(dir)
	if not handle then
		return
	end
	local seen = {}
	while true do
		local name, t = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if t == "file" and name:sub(-#ext) == ext then
			local path = dir .. name
			local stat = uv.fs_stat(path)
			local mt = stat and stat.mtime.sec or 0
			seen[path] = true
			if not file_cache[path] or file_cache[path].mtime ~= mt then
				local lines = {}
				for l in io.lines(path) do
					table.insert(lines, l)
				end
				file_cache[path] = { mtime = mt, lines = lines }
			end
		end
	end
	for p in pairs(file_cache) do
		if not seen[p] then
			file_cache[p] = nil
		end
	end
end

--------------------------------------------------
-- Parse prompt ➜ tokens (underscore becomes space for phrases)
--------------------------------------------------
local function parse_tokens(prompt)
	local tokens = {}

	-- Split by spaces first
	for token in prompt:gmatch("%S+") do
		-- Convert underscores to spaces within each token
		local phrase_token = token:gsub("_", " ")
		table.insert(tokens, phrase_token)
	end

	return tokens
end

--------------------------------------------------
-- Custom sorter that does no filtering (passes everything through)
--------------------------------------------------
local function no_filter_sorter()
	local sorters = require("telescope.sorters")
	return sorters.Sorter:new({
		scoring_function = function(_, prompt, line, entry)
			-- Always return a score of 1 (no filtering, everything passes)
			return 1
		end,
		highlighter = function(_, prompt, display)
			if not prompt or prompt == "" then
				return {}
			end

			local highlights = {}
			local tokens = parse_tokens(prompt)
			local display_lower = display:lower()

			for _, token in ipairs(tokens) do
				local token_lower = token:lower()
				local start_pos = 1

				-- Find all occurrences of this token in the display string
				while true do
					local match_start, match_end = display_lower:find(token_lower, start_pos, true)
					if not match_start then
						break
					end

					-- Add highlight for this match
					table.insert(highlights, {
						start = match_start,
						finish = match_end,
					})

					start_pos = match_end + 1
				end
			end

			-- Sort highlights by start position to avoid overlaps
			table.sort(highlights, function(a, b)
				return a.start < b.start
			end)

			return highlights
		end,
	})
end

--------------------------------------------------
-- Telescope picker
--------------------------------------------------
function M.search(opts)
	opts = opts or {}
	if not check_globals() then
		return
	end

	local telescope = require("telescope")
	local pickers, finders = require("telescope.pickers"), require("telescope.finders")
	local actions, action_st = require("telescope.actions"), require("telescope.actions.state")
	local conf = require("telescope.config").values
	local previewers = require("telescope.previewers")

	-- Candidate generator: one entry per file, tokens act as AND across file
	local function gather(prompt)
		update_file_cache()
		-- Don't strip @@ - let it be searched literally
		prompt = prompt or ""
		local tokens = parse_tokens(prompt)
		local empty = #tokens == 0
		local results = {}

		for path, data in pairs(file_cache) do
			local title = data.lines[1] or ""
			local modified_date = format_timestamp(data.mtime)

			local first_match_line, first_match_idx, extras = nil, nil, {}
			local seen_tok = {}

			for idx, line in ipairs(data.lines) do
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] and line:lower():find(tok:lower(), 1, true) then
						seen_tok[tok] = { idx, line }
						if not first_match_line then
							first_match_idx, first_match_line = idx, line
						end
					end
				end
			end

			local qualifies = empty or true
			if not empty then
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] then
						qualifies = false
						break
					end
				end
			end
			if qualifies then
				if not empty then
					for _, v in pairs(seen_tok) do
						if v[2] ~= first_match_line then
							table.insert(extras, v[2])
						end
					end
				end
				-- local display = { modified_date, title, first_match_line or title }
				local display = { title }
				if #extras > 0 then
					table.insert(display, table.concat(extras, " ∥ "))
				end
				local ord = table.concat(display, " ")
				table.insert(results, {
					value = path .. ":" .. (first_match_idx or 1),
					ordinal = ord,
					display = table.concat(display, " | "),
					filter_text = ord,
					filename = path,
					lnum = first_match_idx or 1,
					text = first_match_line or title,
					header_name = extract_header_name(title),
					mtime = data.mtime,
				})
			end
		end

		-- Sort results by header name (case-insensitive)
		table.sort(results, function(a, b)
			return a.header_name:lower() < b.header_name:lower()
		end)

		return results
	end

	local finder = finders.new_dynamic({
		fn = gather,
		entry_maker = function(e)
			return e
		end,
	})

	-- Use custom no-filter sorter to disable Telescope's filtering
	local sorter = no_filter_sorter()

	-- Previewer: bat markdown or default grep
	local previewer = (vim.fn.executable("bat") == 1)
			and previewers.new_termopen_previewer({
				get_command = function(entry)
					local cmd =
						{ "bat", "--style=numbers,changes", "--color=always", "--language=zortex", entry.filename }
					if entry.lnum then
						table.insert(cmd, 5, "--highlight-line")
						table.insert(cmd, 6, tostring(entry.lnum))
					end
					return cmd
				end,
			})
		or conf.grep_previewer(opts)

	pickers
		.new(opts, {
			prompt_title = "Zortex Search",
			default_text = "@@",
			finder = finder,
			sorter = sorter,
			previewer = previewer,
			attach_mappings = function(bufnr, map)
				actions.select_default:replace(function()
					local sel = action_st.get_selected_entry()
					actions.close(bufnr)
					open_location(sel)
				end)
				map("n", "<C-o>", function()
					create_new_note(bufnr)
				end)
				return true
			end,
		})
		:find()
end

return M
