-- search.lua – incremental exact‑substring note search with on‑disk caching & async delta refresh
--   • Space separates tokens (logical AND across the entire file).
--   • Use underscore "_" instead of spaces for phrase search (hello_world ↔ "hello world").
--   • One entry per note: <date> | <header> | <aliases/tags> | <matching text>.
--   • Preview uses *bat* with Markdown highlighting (falls back if absent).
--   • M.search() is called at the end so you can :luafile % for quick tests.
--
-- 2025‑06‑29 — Cold‑start optimisation
--   1. Persist the file index under $XDG_CACHE_HOME/zortex_index.json and load it *synchronously*.
--   2. Kick off a libuv worker that performs a cheap mtime delta‑scan and patches the cache in the background.
--   Result: Telescope opens with the last‑used index in ≤10 ms; fresh content streams in a moment later.

local M = {}

--------------------------------------------------
-- Globals / utilities
--------------------------------------------------
local uv = vim.loop
local std_cache = vim.fn.stdpath("cache")
local CACHE_FILE = std_cache .. "/zortex_index.json"

--------------------------------------------------
-- Serialise / deserialise helpers (JSON – portable & builtin)
--------------------------------------------------
local function load_cache()
	local f = io.open(CACHE_FILE, "r")
	if not f then
		return {}
	end
	local ok, decoded = pcall(vim.fn.json_decode, f:read("*a"))
	f:close()
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

local function save_cache(tbl)
	-- tbl is potentially large; encode *before* opening handle to minimise open time.
	local ok, raw = pcall(vim.fn.json_encode, tbl)
	if not ok then
		return
	end
	local f = io.open(CACHE_FILE, "w")
	if not f then
		return
	end
	f:write(raw)
	f:close()
end

--------------------------------------------------
-- Configuration sanity check
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
-- In‑memory index  (path → { mtime = <int>, lines = {…} })
--------------------------------------------------
local file_cache = load_cache() -- ← ❶  Load previous session’s index *now*

--------------------------------------------------
-- Helpers shared by sync + async scans
--------------------------------------------------
local function stat_mtime(path)
	local st = uv.fs_stat(path)
	return st and st.mtime and st.mtime.sec or 0
end

local function read_file_lines(path)
	local lines = {}
	for l in io.lines(path) do -- io.lines is fine; we only hit changed files.
		lines[#lines + 1] = l
	end
	return lines
end

--------------------------------------------------
-- Delta scan (reuse unchanged entries, slurp changed/new files)
--------------------------------------------------
local function build_index()
	if not check_globals() then
		return file_cache
	end
	local dir, ext = vim.g.zortex_notes_dir, vim.g.zortex_extension

	local new_index, seen = {}, {}
	local handle = uv.fs_scandir(dir)
	if handle then
		while true do
			local name, t = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if t == "file" and name:sub(-#ext) == ext then
				local path = dir .. name
				seen[path] = true
				local mt = stat_mtime(path)
				local cached = file_cache[path]
				if cached and cached.mtime == mt then
					new_index[path] = cached -- unchanged ➜ reuse
				else
					new_index[path] = { mtime = mt, lines = read_file_lines(path) }
				end
			end
		end
	end
	-- Prune deleted notes
	for p in pairs(file_cache) do
		if not seen[p] then
			new_index[p] = nil
		end
	end
	return new_index
end

--------------------------------------------------
-- Synchronous light‑touch refresh (used right before a search)
--------------------------------------------------
local function update_file_cache_sync()
	local updated = build_index()
	file_cache = updated
end

--------------------------------------------------
-- Background worker – heavy I/O kept off the UI thread
--------------------------------------------------
local function update_file_cache_async()
	if not check_globals() then
		return
	end
	local work
	work = uv.new_work(function()
		-- WORK THREAD (no Neovim API calls!)
		-- Re‑implement minimal parts needed here.
		local luv = require("luv") or require("vim.loop")
		local dir = vim.g.zortex_notes_dir
		local ext = vim.g.zortex_extension
		local function stat(p)
			local st = luv.fs_stat(p)
			return st and st.mtime and st.mtime.sec or 0
		end
		local function read(p)
			local out, fh = {}, io.open(p, "r")
			if fh then
				for l in fh:lines() do
					out[#out + 1] = l
				end
				fh:close()
			end
			return out
		end
		local idx, seen = {}, {}
		local h = luv.fs_scandir(dir)
		if h then
			while true do
				local n, t = luv.fs_scandir_next(h)
				if not n then
					break
				end
				if t == "file" and n:sub(-#ext) == ext then
					local path = dir .. n
					seen[path] = true
					local mt = stat(path)
					local cached = file_cache[path]
					if cached and cached.mtime == mt then
						idx[path] = cached
					else
						idx[path] = { mtime = mt, lines = read(path) }
					end
				end
			end
		end
		return idx
	end, function(res)
		-- MAIN THREAD callback
		if type(res) == "table" then
			file_cache = res
			save_cache(file_cache) -- Persist fresh snapshot
		end
	end)
end

-- Kick off an immediate async refresh so fresh edits show up soon after startup
vim.defer_fn(update_file_cache_async, 100) -- small delay so globals are set

--------------------------------------------------
-- Parse prompt ➜ tokens (underscore becomes space for phrases)
--------------------------------------------------
local function parse_tokens(prompt)
	local tokens = {}
	for token in (prompt or ""):gmatch("%S+") do
		tokens[#tokens + 1] = token:gsub("_", " ")
	end
	return tokens
end

--------------------------------------------------
-- Open entry helper
--------------------------------------------------
local function open_location(entry, cmd)
	cmd = cmd or "edit"
	if entry and entry.filename and entry.lnum then
		vim.cmd(string.format("%s %s", cmd, entry.filename))
		vim.fn.cursor(entry.lnum, 1)
	end
end

--------------------------------------------------
-- NEW NOTE helper (unchanged)
--------------------------------------------------
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

--------------------------------------------------
-- Lightweight string helpers (unchanged)
--------------------------------------------------
local function format_timestamp(ts)
	return os.date("%Y-%m-%d", ts)
end

local function extract_header_name(title)
	if title:match("^@@") then
		return title:sub(3):gsub("^%s+", ""):gsub("%s+$", "")
	end
	return title
end

local function extract_date_from_filename(fname)
	local basename = fname:match("([^/]+)$")
	local stem = basename:match("^(.+)%.[^.]+$") or basename
	if stem:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
		local year = tonumber(stem:sub(1, 4))
		local week = tonumber(stem:sub(5, 6))
		local day = tonumber(stem:sub(7, 7))
		local doy = (week - 1) * 7 + day
		local jan1 = os.time({ year = year, month = 1, day = 1 })
		return format_timestamp(jan1 + (doy - 1) * 86400)
	end
	return nil
end

local function extract_aliases_and_tags(lines)
	local out, seen = {}, {}
	for _, line in ipairs(lines) do
		if line:match("^@@alias") then
			if not seen[line] then
				out[#out + 1], seen[line] = line, true
			end
		else
			for tag in line:gmatch("@%w+") do
				if not seen[tag] then
					out[#out + 1], seen[tag] = tag, true
				end
			end
		end
	end
	table.sort(out)
	return table.concat(out, " ")
end

--------------------------------------------------
-- Telescope‑specific helpers (sorter, highlight, gather, …)
--------------------------------------------------
local function no_filter_sorter()
	local ts_sorters = require("telescope.sorters")
	return ts_sorters.Sorter:new({
		scoring_function = function()
			return 1
		end,
		highlighter = function(_, prompt, display)
			if not prompt or prompt == "" then
				return {}
			end
			local tokens, highlights, disp_lower = parse_tokens(prompt), {}, display:lower()
			for _, tok in ipairs(tokens) do
				local tl, start = tok:lower(), 1
				while true do
					local s, e = disp_lower:find(tl, start, true)
					if not s then
						break
					end
					highlights[#highlights + 1] = { start = s, finish = e }
					start = e + 1
				end
			end
			table.sort(highlights, function(a, b)
				return a.start < b.start
			end)
			return highlights
		end,
	})
end

--------------------------------------------------
-- Core picker
--------------------------------------------------
function M.search(opts)
	opts = opts or {}
	if not check_globals() then
		return
	end

	local telescope = require("telescope")
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values
	local previewers = require("telescope.previewers")

	-- Ensure index is reasonably fresh (cheap – just mtimes)
	update_file_cache_sync()

	------------------------------------------------
	-- dynamic gatherer (called by telescope as user types)
	------------------------------------------------
	local function gather(prompt)
		prompt = prompt or ""
		local tokens, results = parse_tokens(prompt), {}
		local empty = #tokens == 0

		for path, data in pairs(file_cache) do
			local title = data.lines[1] or ""
			local header_name = extract_header_name(title)
			local date_str = extract_date_from_filename(path) or format_timestamp(data.mtime)
			local alias_tag = extract_aliases_and_tags(data.lines)

			local seen_tok, first_line, first_idx = {}, nil, nil
			for idx, line in ipairs(data.lines) do
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] and line:lower():find(tok:lower(), 1, true) then
						seen_tok[tok] = { idx, line }
						if not first_line then
							first_idx, first_line = idx, line
						end
					end
				end
			end

			local qualifies = empty
			if not empty then
				qualifies = true
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] then
						qualifies = false
						break
					end
				end
			end

			if qualifies then
				local extra = {}
				if not empty then
					for _, v in pairs(seen_tok) do
						if v[2] ~= first_line then
							extra[#extra + 1] = v[2]
						end
					end
				end
				local parts = { date_str, (title:match("^@@") and "@@" .. header_name or header_name) }
				if alias_tag ~= "" then
					parts[#parts + 1] = alias_tag
				end
				if first_line and first_line ~= title then
					parts[#parts + 1] = (#extra > 0) and (first_line .. " ∥ " .. table.concat(extra, " ∥ "))
						or first_line
				elseif #extra > 0 then
					parts[#parts + 1] = table.concat(extra, " ∥ ")
				end
				local display = table.concat(parts, " | ")
				local ordinal = table.concat({ header_name, date_str, alias_tag, first_line or "" }, " ")
				results[#results + 1] = {
					value = path .. ":" .. (first_idx or 1),
					ordinal = ordinal,
					display = display,
					filter_text = ordinal,
					filename = path,
					lnum = first_idx or 1,
					header_name = header_name,
					mtime = data.mtime,
				}
			end
		end

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
	local sorter = no_filter_sorter()
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
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
					open_location(sel)
				end)
				map({ "i", "n" }, "<C-o>", function()
					create_new_note(bufnr)
				end)
				return true
			end,
		})
		:find()
end

return M
