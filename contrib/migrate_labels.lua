-- contrib/migrate_labels.lua - One-time conversion to the "::" label syntax
--
-- Rewrites notes written with the old labels to the new ones:
--
--   **Bold heading:**            ->  Bold heading:::
--   Label:                       ->  Label::
--   *A longer label like this:*  ->  A longer label like this::
--   - Bulleted label:            ->  - Bulleted label::
--
-- A line is converted exactly when the old parser read it as a label: a
-- "Text:" line of at most `words` words (attributes not counted; default 3,
-- your old syntax.label_max_words), no sentence (". ") and nothing after the
-- colon, or a starred "*Text:*" label. The header, code blocks and math
-- blocks are left alone. Everything else is untouched.
--
-- From a shell (files, or folders searched for *.zortex; .dot folders are
-- skipped). --dry-run prints the changes without writing:
--
--   nvim -l contrib/migrate_labels.lua --dry-run ~/zortex
--   nvim -l contrib/migrate_labels.lua --words 5 ~/zortex
--
-- From Neovim, :luafile this file, then:
--
--   :ZortexMigrateLabels              the current buffer (one undo step)
--   :ZortexMigrateLabels ~/zortex     every note under a folder, on disk
--   :ZortexMigrateLabels! ~/zortex    the same, a dry run
--
-- Run it once, before using the new syntax: a second run is harmless (the
-- new forms are never old labels), but notes edited in between may hold
-- "Label:" lines you meant as plain text.

local M = {}

M.WORDS = 3

-- =============================================================================
-- The old grammar (a frozen copy of the parts that decide "is a label")
-- =============================================================================

local function trim(s)
	return (s:match("^%s*(.-)%s*$")) or ""
end

local function strip_attributes(text)
	local s = " " .. text
	s = s:gsub("%s@[%w_]+%b()", "")
	s = s:gsub("%s@[%w_%-]+", "")
	return trim((s:gsub("%s+", " ")))
end

local function word_count(s)
	local n = 0
	for _ in s:gmatch("%S+") do
		n = n + 1
	end
	return n
end

local function match_checkbox(text)
	local mark, sep = text:match("^%[(.)%](%s+)%S")
	if mark then
		return mark, 3 + #sep
	end
end

-- The old list item: its content column (0-based) and checkbox mark
local function item(line)
	local indent = line:match("^%s*")
	local rest = line:sub(#indent + 1)
	local consumed, bullet
	local sp = rest:match("^%-(%s+)")
	if sp then
		consumed, bullet = 1 + #sp, true
	elseif rest:match("^%-%[") or rest == "-" then
		consumed, bullet = 1, true
	else
		local range = rest:match("^%d%d?:%d%d%s*%-%s*%d%d?:%d%d%s+")
		local at = rest:match("^%d%d?:%d%d%s+")
		local num = rest:match("^%d+%.%s+") or rest:match("^%a%.%s+")
		consumed = range and #range or at and #at or num and #num
		if not consumed then
			return nil
		end
	end
	local col = #indent + consumed
	local mark
	if bullet then
		local text = line:sub(col + 1)
		local m, n = match_checkbox(text)
		if m then
			mark = m
		else
			local key, sep = text:match("^(%w[^:]-)(:%s+)")
			if key and not key:find("%.%s") and #key <= 60 then
				mark = match_checkbox(line:sub(col + #key + #sep + 1))
			end
		end
	end
	return { content_col = col, mark = mark }
end

local function star_label(body)
	return body:match("^%*([^*%s][^*]*):%*$")
end

local function colon_line(line)
	local text = line:match("^([^:]+):$")
	return text ~= nil and not text:find("%.%s") and not text:find("%*$")
end

local function is_label(line, body, words)
	if star_label(body) then
		return true
	end
	if not colon_line(line) then
		return false
	end
	return word_count(strip_attributes(body:sub(1, -2))) <= words
end

-- =============================================================================
-- Conversion
-- =============================================================================

--- The new form of one line outside the header and blocks, or nil to keep it.
function M.convert_line(line, words)
	words = words or M.WORDS
	if not line:find("%S") or line:match("^#+%s+%S") or line:match("^@") then
		return nil
	end
	local bold = line:match("^%*%*([^*]+):%*%*%s*$")
	if bold then
		return bold .. ":::"
	end
	if line:match("^%-%-%-+%s*$") or line:match("^%[%^") or line:match("^%s*>%s") then
		return nil
	end
	local it = item(line)
	local indent = #line:match("^%s*")
	local start = it and it.content_col or indent
	local body = line:sub(start + 1)
	if it and it.mark or not is_label(line, body, words) then
		return nil
	end
	local text = star_label(body) or body:sub(1, -2)
	return line:sub(1, start) .. text .. "::"
end

--- Convert a note's lines. Returns the new lines and the changes made
--- ({ lnum, old, new }).
function M.convert(lines, words)
	local out, changes = {}, {}
	local in_header, fence, math_block = true, nil, false
	for lnum, line in ipairs(lines) do
		local new
		if in_header and (line:match("^@") or not line:find("%S")) then
			-- the header: @@names, @tags and blank lines
		else
			in_header = false
			local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
			if fence then
				local close = line:match("^%s*(```+)%s*$") or line:match("^%s*(~~~+)%s*$")
				if close and close:sub(1, 1) == fence:sub(1, 1) and #close >= #fence then
					fence = nil
				end
			elseif math_block then
				if line:match("^%s*%$%$%s*$") then
					math_block = false
				end
			elseif f then
				fence = f
			elseif line:match("^%s*%$%$%s*$") then
				math_block = true
			else
				new = M.convert_line(line, words)
			end
		end
		if new and new ~= line then
			changes[#changes + 1] = { lnum = lnum, old = line, new = new }
			out[lnum] = new
		else
			out[lnum] = line
		end
	end
	return out, changes
end

-- =============================================================================
-- Files
-- =============================================================================

local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	local lines = {}
	for l in (data .. (data:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\r?\n") do
		lines[#lines + 1] = l
	end
	return lines, data:sub(-1) == "\n"
end

local function write(path, lines, newline)
	local f = assert(io.open(path, "wb"))
	f:write(table.concat(lines, "\n") .. (newline and "\n" or ""))
	f:close()
end

-- *.zortex files under `path` (or `path` itself), skipping .dot folders
local function notes_in(path)
	path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
	if vim.fn.isdirectory(path) == 0 then
		return { path }
	end
	local found = {}
	for name, kind in vim.fs.dir(path, {
		depth = math.huge,
		skip = function(dir)
			return not vim.fs.basename(dir):match("^%.")
		end,
	}) do
		if kind == "file" and name:match("%.zortex$") then
			found[#found + 1] = path .. "/" .. name
		end
	end
	table.sort(found)
	return found
end

--- Convert files and folders on disk. Returns { files, lines } changed.
function M.run(paths, opts)
	opts = opts or {}
	local print_ = opts.print or print
	local files, total = 0, 0
	for _, p in ipairs(paths) do
		for _, file in ipairs(notes_in(p)) do
			local lines, newline = read(file)
			if lines then
				local out, changes = M.convert(lines, opts.words)
				if #changes > 0 then
					files, total = files + 1, total + #changes
					print_(("%s: %d line%s"):format(file, #changes, #changes == 1 and "" or "s"))
					if opts.dry_run then
						for _, c in ipairs(changes) do
							print_(("  %d: %s  ->  %s"):format(c.lnum, c.old, c.new))
						end
					else
						write(file, out, newline)
					end
				end
			end
		end
	end
	print_(("%s %d line%s in %d file%s"):format(
		opts.dry_run and "Would change" or "Changed",
		total,
		total == 1 and "" or "s",
		files,
		files == 1 and "" or "s"
	))
	return { files = files, lines = total }
end

--- Convert a buffer in place (one undo step).
function M.buffer(buf, words)
	buf = buf or 0
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local out, changes = M.convert(lines, words)
	for i, c in ipairs(changes) do
		if i > 1 then
			vim.cmd("undojoin")
		end
		vim.api.nvim_buf_set_lines(buf, c.lnum - 1, c.lnum, false, { out[c.lnum] })
	end
	return #changes
end

-- =============================================================================
-- Entry points
-- =============================================================================

local argv = rawget(_G, "arg")
if argv and type(argv[0]) == "string" and argv[0]:match("migrate_labels%.lua$") then
	-- nvim -l contrib/migrate_labels.lua [--dry-run] [--words N] PATH...
	local opts, paths, i = { words = M.WORDS }, {}, 1
	while i <= #argv do
		local a = argv[i]
		if a == "--dry-run" or a == "-n" then
			opts.dry_run = true
		elseif a == "--words" then
			i = i + 1
			opts.words = tonumber(argv[i]) or M.WORDS
		else
			paths[#paths + 1] = a
		end
		i = i + 1
	end
	if #paths == 0 then
		print("usage: nvim -l contrib/migrate_labels.lua [--dry-run] [--words N] PATH...")
		os.exit(2)
	end
	M.run(paths, { dry_run = opts.dry_run, words = opts.words, print = function(s)
		io.stdout:write(s, "\n")
	end })
else
	vim.api.nvim_create_user_command("ZortexMigrateLabels", function(o)
		local words = vim.g.zortex_migrate_words or M.WORDS
		if #o.fargs == 0 then
			local n = M.buffer(0, words)
			vim.notify(("Converted %d label line%s"):format(n, n == 1 and "" or "s"))
		else
			local lines = {}
			M.run(o.fargs, { dry_run = o.bang, words = words, print = function(s)
				lines[#lines + 1] = s
			end })
			vim.notify(table.concat(lines, "\n"))
		end
	end, {
		nargs = "*",
		bang = true,
		complete = "file",
		desc = "Convert old labels to Label:: / Label::: (! = dry run)",
	})
end

return M
