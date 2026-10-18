-- features/join.lua - J that knows zortex lines
--
-- Joining lines in a note drops the markers that only make sense at the
-- start of a line, so the joined text reads right:
--
--   # Heading         # Heading more words      (the joined line's "#"s go)
--   # more words
--
--   - first item      - first item second item  (the joined line's "-",
--   - second item                                with its "[ ]", or "1.")
--
--   Label:            Label text under it       (the label's ":" goes,
--   text under it                                "*Long label:*" -> "*Long label*",
--                                                "**Bold:**" -> "**Bold**")
--
--   > quoted          > quoted more             (the joined line's "> ")
--   > more
--
-- Everything else is Vim's own J (spaces, 'joinspaces', the cursor), and a
-- count or a visual selection joins that many lines, as J does. Lines in
-- code and math blocks are joined as they are. gJ is left alone: it joins
-- exactly what is written. Off with features.join = { enabled = false }.
local M = {}

local Document = require("zortex.core.document")

local CODE_KINDS = { code = true, fence = true, math = true, math_fence = true }

-- The line without its trailing label colon (a label or bold heading that
-- something is joined onto), or nil when it has none to drop.
local function drop_colon(line, d)
	if d.kind == "bold_heading" then
		local s = line:gsub(":%*%*(%s*)$", "**%1", 1)
		return s
	end
	if d.kind ~= "label" then
		return nil
	end
	-- "*A longer label:*"
	if line:match(":%*$") then
		return (line:gsub(":%*$", "*"))
	end
	return (line:gsub(":$", ""))
end

-- The line without its start-of-line marker (a line joined onto the one
-- above), or nil when it has none to drop.
local function drop_marker(line, d)
	if d.kind == "heading" then
		return (line:gsub("^#+%s+", "", 1))
	elseif d.kind == "quote" then
		return (line:gsub("^(%s*)>%s+", "%1", 1))
	end
	local item = d.item
	if not item or item.marker_type == "time" then
		return nil -- a time is the entry's content, not a marker
	end
	-- the marker, and a bullet's checkbox ("- [ ] ")
	local cut = item.marker_col + #item.marker
	local rest = line:sub(cut + 1):gsub("^%s+", "")
	if item.marker_type == "bullet" and item.mark and item.mark_col and not item.key then
		rest = rest:gsub("^%[.%]%s+", "", 1)
	end
	return line:sub(1, item.marker_col) .. rest
end

--- The text of lines first..last after dropping the markers a join drops
--- (they are then joined by Vim's J). Exposed for tests.
---@param lines string[] the lines first..last
---@param infos table[] their core/syntax descriptors
---@return string[]
function M.prepare(lines, infos)
	local out = {}
	for i, line in ipairs(lines) do
		local d = infos[i] or {}
		if CODE_KINDS[d.kind] then
			out[i] = line
		else
			-- syntax.classify on the original line: dropping one marker must
			-- not change what the other rule sees
			if i > 1 then
				line = drop_marker(line, d) or line
			end
			if i < #lines then
				line = drop_colon(line, d) or line
			end
			out[i] = line
		end
	end
	return out
end

-- Join `first` with the lines after it, `count` lines in all (as J).
function M.join(first, count)
	local buf = vim.api.nvim_get_current_buf()
	local total = vim.api.nvim_buf_line_count(buf)
	count = math.max(count or 2, 2)
	local last = math.min(first + count - 1, total)
	if last <= first then
		vim.cmd("normal! J") -- the last line: Vim's own (it beeps)
		return
	end
	local doc = Document.from_buffer(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
	local infos = {}
	for i = first, last do
		infos[#infos + 1] = doc and doc:info(i)
			or require("zortex.core.syntax").classify(lines[i - first + 1])
	end
	local new = M.prepare(lines, infos)
	if not vim.deep_equal(new, lines) then
		vim.api.nvim_buf_set_lines(buf, first - 1, last, false, new)
		-- one undo step with the join
		pcall(vim.cmd, "undojoin")
	end
	vim.api.nvim_win_set_cursor(0, { first, 0 })
	-- the markers are handled above: keep 'formatoptions' j (which drops
	-- 'comments' leaders) from also eating text inside code blocks
	local fo = vim.bo[buf].formatoptions
	vim.bo[buf].formatoptions = fo:gsub("j", "")
	local ok, err = pcall(vim.cmd, "normal! " .. (last - first + 1) .. "J")
	vim.bo[buf].formatoptions = fo
	if not ok then
		error(err, 0)
	end
end

-- Dot-repeat: J goes through 'operatorfunc', which . calls again (with the
-- same count). "g@$" always moves, even on an empty line.
local pending = 2
function M.operator()
	M.join(vim.fn.line("'["), pending)
end

function M.attach(buf)
	local opts = (require("zortex.config").features or {}).join or {}
	if opts.enabled == false then
		return
	end
	vim.keymap.set("n", "J", function()
		pending = math.max(vim.v.count1, 2)
		vim.o.operatorfunc = "v:lua.require'zortex.features.join'.operator"
		vim.api.nvim_feedkeys("g@$", "n", false)
	end, { buffer = buf, silent = true, desc = "Zortex: join lines (drops #, -, > and a label's :)" })
	vim.keymap.set("x", "J", function()
		local a, b = vim.fn.line("v"), vim.fn.line(".")
		if a > b then
			a, b = b, a
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
		M.join(a, b - a + 1)
	end, { buffer = buf, silent = true, desc = "Zortex: join lines (drops #, -, > and a label's :)" })
end

return M
