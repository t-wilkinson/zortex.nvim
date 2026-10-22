-- features/markdown_import.lua - Markdown files to notes
--
--   :ZortexImportMarkdown [path] [--join]    a .md file, or every .md under a
--                                             folder (default: the current
--                                             Markdown buffer, else notes_dir)
--
-- Each `name.md` gets a `name.zortex` next to it (an existing one is kept
-- unless the command has a !); the Markdown files are left as they are, so
-- the relative paths in them still work from the new notes. What changes:
--
--   front matter       title / aliases -> @@Name lines, tags -> @tag lines,
--                      other simple keys -> @key(value), the rest kept in a
--                      ```yaml block under the header
--   the note's name    front matter title, else a lone first "# Title"
--                      (dropped from the body), else the file name
--   headings           setext (Title / ===) -> "# Title"; closing #s and
--                      {#ids} dropped
--   rules              ***, ___, - - - -> ---
--   lists              * and + bullets -> -, "1)" -> "1."
--   code               indented code blocks -> ``` fences
--   tables             rows get their outer | (a note's table rows need them)
--   quotes             ">text" -> "> text"; callouts "> [!note] Title" ->
--                      "> **Note:** Title"
--   links              [[Note]], [[Note#Heading]], [text](note.md#slug) and
--                      reference links -> [Name], [Name/#Heading] (when the
--                      text isn't the note's name it is kept as the link's
--                      text: "[my notes](Sourdough)"); [[#Heading]] -> [/#Heading];
--                      other relative paths get "./" (relative to the note);
--                      <https://…> -> https://…
--   images             ![alt](pic.png) -> ![alt](./pic.png) (![./pic.png]
--                      without alt text); ![[pic.png]] finds the
--                      file among the imported folder's files
--   emphasis           __bold__ -> **bold**, _italic_ -> *italic*
--   tags               #tag -> @tag (#a/b -> @a-b; #123 stays)
--   paragraphs         kept line by line; with --join (opts.join) the lines
--                      of a soft-wrapped paragraph, list item or quote become
--                      one line, as Markdown shows them ("  " and "\" breaks
--                      stay)
--
-- Code (fenced, indented and `inline`) and $math$ are left alone. Bracketed
-- text that isn't a link in Markdown ("[WIP]") would be a link in a note: it
-- is kept and reported (the quickfix list after an import).
local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- =============================================================================
-- Front matter
-- =============================================================================

local function unquote(v)
	v = trim(v)
	local q = v:sub(1, 1)
	if (q == '"' or q == "'") and v:sub(-1) == q and #v >= 2 then
		return v:sub(2, -2)
	end
	return v
end

local function flow_list(v)
	local out = {}
	for item in v:sub(2, -2):gmatch("[^,]+") do
		item = unquote(item)
		if item ~= "" then
			out[#out + 1] = item
		end
	end
	return out
end

--- The front matter at the top of `lines` ("---" … "---"/"..."): its entries
--- { key, value (string or list) or raw (lines kept as YAML) } and the line
--- the body starts at. A small YAML subset: scalars, [flow] and "- " lists.
function M.front_matter(lines)
	if not lines[1] or trim(lines[1]) ~= "---" then
		return nil, 1
	end
	local close
	for i = 2, #lines do
		local t = trim(lines[i])
		if t == "---" or t == "..." then
			close = i
			break
		end
	end
	if not close then
		return nil, 1
	end
	local entries = {}
	local i = 2
	while i < close do
		local line = lines[i]
		local key, value = line:match("^([%w_][%w_%-%.]*):%s*(.-)%s*$")
		if not key then
			i = i + 1 -- a comment, a blank, or what an entry below didn't take
		else
			local entry = { key = key, raw = { line } }
			local j = i + 1
			-- the lines under it (a list, a nested map, a block scalar)
			while j < close and (lines[j]:match("^%s") or lines[j]:match("^%-%s") or not lines[j]:match("%S")) do
				entry.raw[#entry.raw + 1] = lines[j]
				j = j + 1
			end
			while #entry.raw > 1 and not entry.raw[#entry.raw]:match("%S") do
				table.remove(entry.raw)
			end
			if value == "" and #entry.raw > 1 then
				local list = {}
				for k = 2, #entry.raw do
					local item = entry.raw[k]:match("^%s*%-%s+(.-)%s*$")
					if not item then
						list = nil
						break
					end
					list[#list + 1] = unquote(item)
				end
				entry.value = list
			elseif value:match("^%[.*%]$") and #entry.raw == 1 then
				entry.value = flow_list(value)
			elseif value ~= "" and #entry.raw == 1 and not value:match("^[|>]") then
				entry.value = unquote(value)
			end
			entries[#entries + 1] = entry
			i = j
		end
	end
	return entries, close + 1
end

-- "#Projects/Home Work" -> "Projects-Home-Work"
local function tag_word(s)
	s = trim(tostring(s)):gsub("^#", ""):gsub("[/%s]+", "-")
	return (s:gsub("[^%w_%-\128-\255]", ""))
end

local NAME_KEYS = { title = true, name = true }
local ALIAS_KEYS = { aliases = true, alias = true }
local TAG_KEYS = { tags = true, tag = true, keywords = true }

--- Header lines from front matter entries: @@aliases, @tags, @key(value),
--- and the lines kept as YAML. Returns name, header lines, yaml lines.
function M.header_from(entries)
	local name, header, yaml = nil, {}, {}
	local aliases, tags, attrs = {}, {}, {}
	for _, e in ipairs(entries or {}) do
		local k, v = e.key:lower(), e.value
		if NAME_KEYS[k] and type(v) == "string" and v ~= "" and not name then
			name = v
		elseif ALIAS_KEYS[k] and v then
			for _, a in ipairs(type(v) == "table" and v or { v }) do
				aliases[#aliases + 1] = a
			end
		elseif TAG_KEYS[k] and v then
			local list = type(v) == "table" and v or vim.split(v, "[,%s]+", { trimempty = true })
			for _, t in ipairs(list) do
				local w = tag_word(t)
				if w ~= "" then
					tags[#tags + 1] = w
				end
			end
		else
			local value = type(v) == "table" and table.concat(v, ", ") or v
			if value and e.key:match("^[%w_][%w_%-]*$") and not value:find("[()\n]") and value ~= "" then
				attrs[#attrs + 1] = "@" .. e.key .. "(" .. value .. ")"
			else
				vim.list_extend(yaml, e.raw)
			end
		end
	end
	for _, a in ipairs(aliases) do
		header[#header + 1] = "@@" .. a
	end
	for _, t in ipairs(tags) do
		header[#header + 1] = "@" .. t
	end
	vim.list_extend(header, attrs)
	return name, header, yaml
end

-- =============================================================================
-- Blocks
-- =============================================================================

local FENCE = "^%s*([`~][`~][`~]+)"

local function fence_of(line)
	local f = line:match(FENCE)
	if f and (f:match("^`+$") or f:match("^~+$")) then
		return f
	end
end

local function blank(line)
	return not line:match("%S")
end

local function is_rule(line)
	local t = line:match("^ ? ? ?(.-)%s*$")
	for _, c in ipairs({ "%-", "%*", "_" }) do
		local stripped = t:gsub("%s", "")
		if #stripped >= 3 and stripped:match("^" .. c .. "+$") then
			return true
		end
	end
	return false
end

local function is_item(line)
	return line:match("^%s*[-*+]%s") or line:match("^%s*%d+[.)]%s")
end

-- "|---|:--:|", "--- | ---": a table's delimiter row
local function is_table_delim(line)
	if not line:find("|", 1, true) then
		return false
	end
	local inner = vim.trim(line):gsub("^|", ""):gsub("|$", "")
	for cell in (inner .. "|"):gmatch("([^|]*)|") do
		if not cell:match("^%s*:?%-+:?%s*$") then
			return false
		end
	end
	return true
end

-- A paragraph line: what Markdown flows into the line above it.
local function plain(line)
	return not (
		blank(line)
		or line:match("^%s*#+%s")
		or line:match("^%s*>")
		or fence_of(line)
		or is_item(line)
		or line:match("^%s*|")
		or is_rule(line)
		or line:match("^%s*%$%$")
		or line:match("^%s*<")
	)
end

-- "| a | b |" from "a | b"
local function piped(line)
	local indent, rest = line:match("^(%s*)(.-)%s*$")
	if not rest:match("^|") then
		rest = "| " .. rest
	end
	if not rest:match("|$") or rest:match("\\|$") then
		rest = rest .. " |"
	end
	return indent .. rest
end

local CALLOUT = "^(%s*>%s*)%[!(%a+)%][+-]?%s*(.-)%s*$"

--- The block-level pass: setext headings, rules, bullets, indented code,
--- tables, quotes and callouts. Returns lines, and the code lines (line ->
--- true) the inline pass leaves alone.
function M.blocks(lines, opts)
	opts = opts or {}
	local out, code = {}, {}
	local fence -- the open fence's characters
	local i = 1
	local function push(l, is_code)
		out[#out + 1] = l
		if is_code then
			code[#out] = true
		end
	end
	local function prev_nonblank()
		for k = #out, 1, -1 do
			if not blank(out[k]) then
				return out[k], k
			end
		end
	end
	local math_block = false
	while i <= #lines do
		local line = lines[i]
		if fence then
			push(line, true)
			local f = fence_of(line)
			if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence and line:match("^%s*[`~]+%s*$") then
				fence = nil
			end
			i = i + 1
		elseif fence_of(line) then
			fence = fence_of(line)
			push(line, true)
			i = i + 1
		elseif math_block or line:match("^%s*%$%$%s*$") then
			if line:match("^%s*%$%$%s*$") then
				math_block = not math_block
			end
			push(line, true)
			i = i + 1
		elseif
			-- indented code: after a blank line, not under a list item
			(line:match("^    ") or line:match("^\t"))
			and (i == 1 or blank(lines[i - 1]))
			and not (function()
				local p = prev_nonblank()
				return p and (is_item(p) or p:match("^%s%s"))
			end)()
		then
			local block = {}
			while i <= #lines and (lines[i]:match("^    ") or lines[i]:match("^\t") or blank(lines[i])) do
				block[#block + 1] = lines[i]:gsub("^    ", ""):gsub("^\t", "")
				i = i + 1
			end
			local trailing = 0
			while #block > 0 and blank(block[#block]) do
				table.remove(block)
				trailing = trailing + 1
			end
			push("```", true)
			for _, l in ipairs(block) do
				push(l, true)
			end
			push("```", true)
			for _ = 1, trailing do
				push("")
			end
		elseif
			-- setext: a paragraph line over === or ---
			plain(line)
			and lines[i + 1]
			and (lines[i + 1]:match("^ ? ? ?=+%s*$") or lines[i + 1]:match("^ ? ? ?%-+%s*$"))
			and (#out == 0 or blank(out[#out]) or not plain(out[#out]))
		then
			local level = lines[i + 1]:match("=") and "#" or "##"
			push(level .. " " .. trim(line))
			i = i + 2
		elseif is_rule(line) then
			push("---")
			i = i + 1
		elseif line:match("^ ? ? ?#+%s") or line:match("^ ? ? ?#+$") then
			local hashes, text = line:match("^ ? ? ?(#+)%s*(.-)%s*$")
			text = text:gsub("%s+#+$", ""):gsub("^#+$", ""):gsub("%s*{[#.][^}]*}$", "")
			if #hashes <= 6 and text ~= "" then
				push(hashes .. " " .. text)
			elseif #hashes <= 6 then
				-- an empty heading: nothing to keep
			else
				push(line)
			end
			i = i + 1
		elseif
			-- a table: a row over a delimiter row
			line:find("|", 1, true)
			and not line:match("^%s*>")
			and lines[i + 1]
			and is_table_delim(lines[i + 1])
		then
			push(piped(line))
			push(piped(lines[i + 1]))
			i = i + 2
			while i <= #lines and lines[i]:find("|", 1, true) and not blank(lines[i]) do
				push(piped(lines[i]))
				i = i + 1
			end
		else
			-- bullets and ordered markers
			local l = line
			if not is_rule(l) then
				l = l:gsub("^(%s*)[*+](%s+)", "%1-%2", 1):gsub("^(%s*)(%d+)%)(%s+)", "%1%2.%3", 1)
			end
			-- quotes and callouts
			local pre, kind, title = l:match(CALLOUT)
			if pre then
				kind = kind:sub(1, 1):upper() .. kind:sub(2):lower()
				l = (pre:gsub("%s*$", "") .. " **" .. kind .. ":**" .. (title ~= "" and (" " .. title) or ""))
			elseif l:match("^%s*>+%s*$") then
				l = "" -- an empty quote line: a break between quoted paragraphs
			else
				l = l:gsub("^(%s*)>(%S)", "%1> %2", 1)
			end
			push(l)
			i = i + 1
		end
	end
	if opts.join then
		out, code = M.join(out, code)
	end
	return out, code
end

-- With --join: a line Markdown flows into the one above it is joined to it.
-- A line ending in "  " or "\" ends its line; that marker goes.
function M.join(lines, code)
	local out, out_code = {}, {}
	local open = false -- the last line can take the next one
	local quote = false
	for i, line in ipairs(lines) do
		if code[i] then
			out[#out + 1] = line
			out_code[#out] = true
			open = false
		else
			local hard = line:match("  $") or (line:match("\\$") and not line:match("\\\\$"))
			local text = line:gsub("%s+$", ""):gsub("\\$", "")
			local q = text:match("^%s*>%s(.*)$")
			if open and quote and q and plain(q) then
				out[#out] = out[#out] .. " " .. trim(q)
			elseif open and not quote and plain(text) then
				out[#out] = out[#out] .. " " .. trim(text)
			else
				out[#out + 1] = text
				quote = q ~= nil
			end
			local last = out[#out]
			open = not hard
				and not blank(last)
				and not last:match("^%s*#+%s")
				and not last:match("^%s*|")
				and not is_rule(last)
				-- a label (three words at most): the line under it is its content
				and require("zortex.core.syntax").classify(last).kind ~= "label"
		end
	end
	return out, out_code
end

-- =============================================================================
-- Inline
-- =============================================================================

--- GitHub's heading id: lower case, punctuation dropped, spaces to dashes
--- (as app/web markdown.go slug); `seen` numbers repeats.
function M.slug(text, seen)
	text = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
	local id = text:gsub(" ", "-"):gsub("[^%w%-_\128-\255]", "")
	if seen then
		local n = seen[id] or 0
		seen[id] = n + 1
		if n > 0 then
			id = id .. "-" .. n
		end
	end
	return id
end

local function is_url(s)
	return s:match("^%a[%w+.-]*:") ~= nil
end

-- "pics/a.png" -> "./pics/a.png" (a note reads plain relative paths from the
-- notes folder; Markdown from the file's own folder)
local function local_path(p)
	if is_url(p) or p:match("^[./~#]") then
		return p
	end
	return "./" .. p
end

local function link_text(s)
	return require("zortex.core.link").component_text(s)
end

-- "[Name/#Heading]", with the text in front when it isn't the name (or one
-- of `also`: the file name it was written as)
local function note_link(text, name, heading, also)
	local def = name and link_text(name) or ""
	if heading and heading ~= "" then
		def = def .. "/#" .. link_text(heading)
	end
	if def == "" then
		return text or ""
	end
	local link = "[" .. def .. "]"
	text = text and trim(text) or ""
	local same = text == ""
		or text:lower() == (name or ""):lower()
		or text:lower() == (heading or ""):lower()
		or (name and heading and text:lower() == (name .. "#" .. heading):lower())
	for _, a in ipairs(also or {}) do
		same = same or text:lower() == a:lower()
	end
	if same then
		return link
	end
	-- "(" or ")" in the definition can't be written inside "(…)"
	return def:find("[()]") and (text .. " " .. link) or ("[" .. text .. "](" .. def .. ")")
end

-- Segments of `line` that are code or math (left alone): { s, e } 1-based.
local function protected(line)
	local out = {}
	local i = 1
	while i <= #line do
		local ticks = line:match("^`+", i)
		if ticks then
			local close = line:find(ticks, i + #ticks, true)
			while close and line:sub(close + #ticks, close + #ticks) == "`" do
				close = line:find(ticks, close + #ticks + 1, true)
			end
			if close then
				out[#out + 1] = { i, close + #ticks - 1 }
				i = close + #ticks
			else
				i = i + #ticks
			end
		elseif line:sub(i, i) == "$" and line:sub(i + 1, i + 1):match("%S") and line:sub(i + 1, i + 1) ~= "$" then
			local close = line:find("%$", i + 1)
			if close and line:sub(close - 1, close - 1):match("%S") then
				out[#out + 1] = { i, close }
				i = close + 1
			else
				i = i + 1
			end
		else
			i = i + 1
		end
	end
	return out
end

-- Apply fn to the parts of `line` outside code and math.
local function outside_code(line, fn)
	local parts, pos = {}, 1
	for _, r in ipairs(protected(line)) do
		parts[#parts + 1] = fn(line:sub(pos, r[1] - 1))
		parts[#parts + 1] = line:sub(r[1], r[2])
		pos = r[2] + 1
	end
	parts[#parts + 1] = fn(line:sub(pos))
	return table.concat(parts)
end

--- One line's inline Markdown as a note's. ctx: { refs, resolve(target) ->
--- { name, headings? }, file(name) -> path, here (this note's headings),
--- warn(msg) }.
function M.inline(line, ctx)
	ctx = ctx or {}
	local resolve = ctx.resolve or function() end
	local placeholders = {}
	-- links made here are set aside, so later rules don't read inside them
	local function keep(s)
		placeholders[#placeholders + 1] = s
		return "\0" .. #placeholders .. "\0"
	end

	-- a Markdown target -> a link, an image path, or nil to keep it
	local function heading_of(info, anchor)
		if not anchor or anchor == "" then
			return nil
		end
		for _, h in ipairs(info and info.headings or {}) do
			if h.slug == anchor:lower() or h.text:lower() == anchor:lower() then
				return h.text
			end
		end
		return (anchor:gsub("%-", " "))
	end
	local function md_link(text, url)
		url = url:gsub("^<(.*)>$", "%1")
		if is_url(url) then
			return keep("[" .. text .. "](" .. url .. ")")
		end
		local path, anchor = url:match("^([^#]*)#?(.*)$")
		if path == "" and anchor ~= "" then
			return keep(note_link(text, nil, heading_of({ headings = ctx.here }, anchor)))
		end
		local target = path:gsub("%%(%x%x)", function(h)
			return string.char(tonumber(h, 16))
		end):gsub("^%./", "")
		-- a Markdown file (or a name without an extension) that is a note now
		local info = (target:match("%.md$") or target:match("%.markdown$") or not target:match("%.%w+$")) and resolve(target)
			or nil
		if info then
			local base = target:match("[^/]+$") or target
			return keep(note_link(text, info.name, heading_of(info, anchor), { target, base, (base:gsub("%.%w+$", "")) }))
		end
		return keep("[" .. text .. "](" .. local_path(url) .. ")")
	end

	local converted = outside_code(line, function(s)
		-- images ![alt](src "title"), and Obsidian embeds ![[file|size]]
		s = s:gsub("!%[%[([^%]|#]+)[^%]]*%]%]", function(target)
			target = trim(target)
			if target:match("%.%w+$") and not target:match("%.md$") then
				local path = ctx.file and ctx.file(target) or nil
				return keep("![" .. local_path(path or target) .. "]")
			end
			local info = resolve(target)
			return keep("![" .. link_text(info and info.name or target) .. "]")
		end)
		s = s:gsub("!%[([^%]]*)%]%(%s*<?([^%s)>]+)>?[^)]*%)", function(alt, src)
			alt = trim(alt)
			if alt == "" then
				return keep("![" .. local_path(src) .. "]")
			end
			return keep("![" .. alt .. "](" .. local_path(src) .. ")")
		end)
		-- wikilinks [[target#heading|text]]
		s = s:gsub("%[%[([^%]]+)%]%]", function(inner)
			local target, alias = inner:match("^(.-)|(.*)$")
			target = target or inner
			local note, heading = target:match("^(.-)#(.*)$")
			note = trim(note or target)
			if heading and heading:match("^%^") then
				heading = nil -- a block id
			end
			if note == "" then
				return keep(heading and ((alias and (trim(alias) .. " ") or "") .. "[/#" .. link_text(heading) .. "]") or inner)
			end
			local info = resolve(note)
			local name = info and info.name or note:gsub("^.*/", ""):gsub("%.md$", "")
			return keep(note_link(alias or "", name, heading, { note, (note:gsub("^.*/", "")) }))
		end)
		-- [text](url "title")
		s = s:gsub("%[([^%]]*)%]%(%s*(<[^>]*>)%s*[^)]*%)", md_link)
		s = s:gsub("%[([^%]]*)%]%(%s*([^%s)]+)%s*[^)]*%)", md_link)
		-- reference links [text][id], [text][], [id]
		s = s:gsub("%[([^%]]*)%]%[([^%]]*)%]", function(text, id)
			local ref = (ctx.refs or {})[(id ~= "" and id or text):lower()]
			if ref then
				return md_link(text, ref)
			end
		end)
		s = s:gsub("%[([^%]^][^%]]*)%]", function(id)
			local ref = (ctx.refs or {})[id:lower()]
			if ref then
				return md_link(id, ref)
			end
		end)
		-- autolinks <https://…>
		s = s:gsub("<(%a[%w+.-]*:[^%s>]+)>", function(u)
			return keep(u)
		end)
		-- emphasis
		s = s:gsub("%f[%w_]__([^_%s][^_]-[^_%s])__%f[^%w_]", "**%1**")
		s = s:gsub("%f[%w_]__([^_%s])__%f[^%w_]", "**%1**")
		s = s:gsub("%f[%w_]_([^_%s][^_]-[^_%s])_%f[^%w_]", "*%1*")
		s = s:gsub("%f[%w_]_([^_%s])_%f[^%w_]", "*%1*")
		-- tags: #tag -> @tag
		s = s:gsub("()#([%w_][%w_%-/]*)", function(pos, tag)
			local before = pos > 1 and s:sub(pos - 1, pos - 1) or ""
			if (before ~= "" and not before:match("[%s(]")) or not tag:match("[%a_]") then
				return nil
			end
			return "@" .. tag_word(tag)
		end)
		-- [brackets] left: a link in a note
		if ctx.warn then
			for inner in s:gmatch("%[([^%]]+)%]") do
				if #inner > 1 and not inner:match("^%^") and not inner:match("^[ xX>]$") then
					ctx.warn("[" .. inner .. "] reads as a link in a note")
				end
			end
		end
		return s
	end)
	-- the links set aside go back (twice: a link's text may hold one)
	for _ = 1, 2 do
		converted = converted:gsub("%z(%d+)%z", function(n)
			return placeholders[tonumber(n)]
		end)
	end
	return converted
end

-- =============================================================================
-- A whole file
-- =============================================================================

--- The headings of Markdown `lines` (after M.blocks): { { text, slug } }.
function M.headings(lines)
	local out, seen, fence = {}, {}, nil
	for _, line in ipairs(lines) do
		local f = fence_of(line)
		if fence then
			if f and f:sub(1, 1) == fence then
				fence = nil
			end
		elseif f then
			fence = f:sub(1, 1)
		else
			local text = line:match("^#+%s+(.-)%s*$")
			if text then
				local plain_text = text:gsub("%[([^%]]*)%]%([^)]*%)", "%1"):gsub("[*_`]", "")
				-- the link to it stops where a #tag (an @tag in the note) starts
				local name = plain_text:gsub("(%s)#([%w_])", "%1@%2")
				out[#out + 1] = { text = name, slug = M.slug(plain_text, seen) }
			end
		end
	end
	return out
end

local REF_DEF = "^ ? ? ?%[([^%]^][^%]]*)%]:%s*<?([^%s>]+)>?.*$"

--- The note's name and the parts a conversion needs, without converting:
--- { name, header, yaml, body (blocks done), code, refs, headings }.
function M.prepare(lines, opts)
	opts = opts or {}
	lines = vim.list_slice(lines)
	if lines[1] then
		lines[1] = lines[1]:gsub("^\239\187\191", "")
	end
	local entries, start = M.front_matter(lines)
	local name, header, yaml = M.header_from(entries)
	local body, code = M.blocks(vim.list_slice(lines, start), opts)
	-- reference definitions: used by the links, then dropped
	local refs, kept, kept_code = {}, {}, {}
	for i, l in ipairs(body) do
		local id, url = l:match(REF_DEF)
		if id and not code[i] then
			refs[id:lower()] = refs[id:lower()] or url
		else
			kept[#kept + 1] = l
			kept_code[#kept] = code[i]
		end
	end
	body, code = kept, kept_code
	-- the name: front matter, else a lone first "# Title", else the file's
	local first
	for i, l in ipairs(body) do
		if not blank(l) then
			first = i
			break
		end
	end
	local h1s = 0
	for i, l in ipairs(body) do
		if not code[i] and l:match("^#%s") then
			h1s = h1s + 1
		end
	end
	local title = first and body[first]:match("^#%s+(.-)%s*$")
	if title and (not name and h1s == 1 or (name and title:lower() == name:lower())) then
		name = name or title
		table.remove(body, first)
		local shifted = {}
		for i in pairs(code) do
			shifted[i > first and i - 1 or i] = true
		end
		code = shifted
	end
	name = name or opts.name or "Untitled"
	return {
		name = name,
		header = header,
		yaml = yaml,
		body = body,
		code = code,
		refs = refs,
		headings = M.headings(body),
	}
end

--- Markdown `lines` as a note's lines. opts: { name (the file's), join,
--- resolve(target) -> { name, headings }, file(name) -> path }. Returns the
--- lines and the warnings { { lnum, text } } (lnum in the new note).
function M.convert(lines, opts)
	opts = opts or {}
	local p = opts.prepared or M.prepare(lines, opts)
	local out = { "@@" .. p.name }
	vim.list_extend(out, p.header)
	out[#out + 1] = ""
	if #p.yaml > 0 then
		out[#out + 1] = "```yaml"
		vim.list_extend(out, p.yaml)
		out[#out + 1] = "```"
		out[#out + 1] = ""
	end
	local warnings = {}
	local started = false
	for i, l in ipairs(p.body) do
		if started or not blank(l) then
			started = true
			if p.code[i] then
				out[#out + 1] = l
			else
				local lnum = #out + 1
				out[#out + 1] = M.inline(l, {
					refs = p.refs,
					resolve = opts.resolve,
					file = opts.file,
					here = p.headings,
					warn = function(msg)
						warnings[#warnings + 1] = { lnum = lnum, text = msg }
					end,
				})
			end
		end
	end
	while #out > 1 and blank(out[#out]) do
		table.remove(out)
	end
	return out, warnings
end

-- =============================================================================
-- Files and folders
-- =============================================================================

local SKIP_DIRS = { [".git"] = true, [".obsidian"] = true, [".trash"] = true, ["node_modules"] = true, [".z"] = true }

local function walk(dir, fn)
	for name, kind in vim.fs.dir(dir) do
		local path = dir .. "/" .. name
		if kind == "directory" then
			if not SKIP_DIRS[name] and not name:match("^%.") then
				walk(path, fn)
			end
		elseif kind == "file" or kind == "link" then
			fn(path, name)
		end
	end
end

local function is_md(path)
	return path:match("%.md$") or path:match("%.markdown$")
end

local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	if s:sub(-1) == "\n" then
		s = s:sub(1, -2)
	end
	return vim.split(s, "\n", { plain = true })
end

local function relative(from_dir, path)
	local a = vim.split(vim.fs.normalize(from_dir), "/", { trimempty = true })
	local b = vim.split(vim.fs.normalize(path), "/", { trimempty = true })
	local i = 1
	while a[i] and b[i] and a[i] == b[i] do
		i = i + 1
	end
	local parts = {}
	for _ = i, #a do
		parts[#parts + 1] = ".."
	end
	for k = i, #b do
		parts[#parts + 1] = b[k]
	end
	local rel = table.concat(parts, "/")
	return rel:match("^%.%.") and rel or ("./" .. rel)
end

--- Convert a Markdown file, or every one under a folder. opts: { join,
--- force (overwrite .zortex files), write = false (only report) }.
--- Returns { converted = { path }, skipped = { path }, warnings = qf items }.
function M.import(path, opts)
	opts = opts or {}
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
	local root = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
	local files, others = {}, {}
	if vim.fn.isdirectory(path) == 1 then
		walk(path, function(p, name)
			if is_md(p) then
				files[#files + 1] = p
			else
				local k = name:lower()
				others[k] = others[k] or p
			end
		end)
	elseif is_md(path) then
		files[1] = path
		walk(root, function(p, name)
			if not is_md(p) then
				local k = name:lower()
				others[k] = others[k] or p
			end
		end)
	end
	table.sort(files)
	-- every note's name first, so links between them resolve
	local notes, by = {}, {}
	for _, f in ipairs(files) do
		local lines = read(f) or {}
		local base = vim.fn.fnamemodify(f, ":t:r")
		local p = M.prepare(lines, { name = base, join = opts.join })
		local n = { path = f, lines = lines, prepared = p, name = p.name, headings = p.headings }
		notes[#notes + 1] = n
		local rel = f:sub(#root + 2):gsub("%.m[a-z]*$", ""):lower()
		for _, key in ipairs({ base:lower(), rel, p.name:lower() }) do
			by[key] = by[key] or n
		end
	end
	local result = { converted = {}, skipped = {}, warnings = {} }
	for _, n in ipairs(notes) do
		local dir = vim.fn.fnamemodify(n.path, ":h")
		local out, warnings = M.convert(n.lines, {
			prepared = n.prepared,
			resolve = function(target)
				target = target:gsub("^%./", ""):gsub("%.m[a-z]*$", "")
				local key = target:lower()
				local hit = by[key] or by[vim.fn.simplify(dir .. "/" .. target):sub(#root + 2):lower()]
				return hit and { name = hit.name, headings = hit.headings } or nil
			end,
			file = function(name)
				local hit = others[vim.fn.fnamemodify(name, ":t"):lower()]
				return hit and relative(dir, hit) or nil
			end,
		})
		local dest = n.path:gsub("%.m[a-z]*$", "") .. ".zortex"
		if vim.fn.filereadable(dest) == 1 and not opts.force then
			result.skipped[#result.skipped + 1] = dest
		else
			if opts.write ~= false then
				vim.fn.writefile(out, dest)
				require("zortex.core.document").invalidate(dest)
			end
			result.converted[#result.converted + 1] = dest
			for _, w in ipairs(warnings) do
				result.warnings[#result.warnings + 1] = { filename = dest, lnum = w.lnum, col = 1, text = w.text }
			end
		end
	end
	return result
end

--- :ZortexImportMarkdown[!] [path] [--join]
function M.command(args)
	local fargs = vim.deepcopy(args and args.fargs or {})
	local join = false
	for i = #fargs, 1, -1 do
		if fargs[i] == "--join" then
			join = true
			table.remove(fargs, i)
		end
	end
	local path = fargs[1]
	if not path or path == "" then
		local current = vim.api.nvim_buf_get_name(0)
		path = is_md(current) and current or require("zortex.config").notes_dir
	end
	path = vim.fn.expand(path)
	if vim.fn.isdirectory(path) == 1 then
		local count = 0
		walk(vim.fn.fnamemodify(path, ":p"):gsub("/$", ""), function(p)
			if is_md(p) then
				count = count + 1
			end
		end)
		if count == 0 then
			return vim.notify("No Markdown files under " .. path, vim.log.levels.INFO, { title = "Zortex" })
		end
		local answer = vim.fn.confirm(
			string.format("Convert %d Markdown file%s under %s to notes next to them?", count, count == 1 and "" or "s", path),
			"&Yes\n&No",
			2
		)
		if answer ~= 1 then
			return
		end
	elseif not is_md(path) then
		return vim.notify("Not a Markdown file or folder: " .. path, vim.log.levels.WARN, { title = "Zortex" })
	end
	local res = M.import(path, { join = join, force = args and args.bang })
	local msg = string.format("%d note%s written", #res.converted, #res.converted == 1 and "" or "s")
	if #res.skipped > 0 then
		msg = msg .. string.format(", %d kept (a .zortex was there; ! overwrites)", #res.skipped)
	end
	if #res.warnings > 0 then
		vim.fn.setqflist({}, "r", { title = "Markdown import: lines to check", items = res.warnings })
		msg = msg .. string.format(", %d line%s to check (quickfix)", #res.warnings, #res.warnings == 1 and "" or "s")
		vim.cmd("copen")
	end
	require("zortex.core.link_index").refresh(true)
	vim.notify(msg, vim.log.levels.INFO, { title = "Zortex" })
	return res
end

return M
