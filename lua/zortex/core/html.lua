-- core/html.lua - An HTML page as a note
--
-- convert(text, rel) reads an HTML file (an AI-written page in z/html, say)
-- and writes it as a note, so its headings are sections that links, search
-- and completion reach ([Rust ownership/#Borrowing]). core/documents keeps
-- the result in .z/html/ (what Neovim opens); `zortex serve` converts the
-- same way (app/notes/html.go, checked against tests/fixtures/html).
--
--   @@<title>                 <title>, else the first <h1>, else the file name
--   @@<file name>             when it differs from the title
--
--   From [z/html/a.html](/raw/z/html/a.html)
--
--   # Heading                 <h1>…<h6>
--   A paragraph.              <p>, and the text of <div>, <section>, …
--   - item / 1. item          <ul>, <ol> (nested two spaces deeper)
--   > quoted                  <blockquote>
--   ```lang … ```             <pre> (lang from class="language-…")
--   | a | b |                 <table> rows (|---| after a row of <th>)
--   ---                       <hr>
--   **b** *i* `code` [t](u) ![alt](src)
--
-- <script>, <style>, <head>, <nav>, <svg>, <button>, … are left out. Only
-- bytes are compared (ASCII case), so Lua and Go agree on any text.
local M = {}

local function set(list)
	local s = {}
	for _, k in ipairs(list) do
		s[k] = true
	end
	return s
end

local VOID = set({ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" })
-- their content is text up to </name>
local RAW = set({ "script", "style", "textarea", "title" })
-- left out, with what is inside
local DROP = set({
	"script",
	"style",
	"noscript",
	"template",
	"head",
	"title",
	"nav",
	"svg",
	"math",
	"button",
	"select",
	"textarea",
	"iframe",
	"canvas",
	"object",
})
local BLOCK = set({
	"html",
	"body",
	"main",
	"article",
	"section",
	"header",
	"footer",
	"aside",
	"div",
	"p",
	"blockquote",
	"figure",
	"figcaption",
	"address",
	"center",
	"details",
	"summary",
	"form",
	"fieldset",
	"ul",
	"ol",
	"li",
	"dl",
	"dt",
	"dd",
	"h1",
	"h2",
	"h3",
	"h4",
	"h5",
	"h6",
	"pre",
	"hr",
	"table",
	"caption",
	"thead",
	"tbody",
	"tfoot",
	"tr",
	"td",
	"th",
})
M._BLOCK = BLOCK

-- ASCII only: the same bytes in every locale, and in Go
local function lower(s)
	return (s:gsub("[A-Z]", function(c)
		return string.char(c:byte() + 32)
	end))
end
M.lower = lower

local SPACE = "[ \t\n\r\f\v]"
local function trim(s)
	return (s:gsub("^" .. SPACE .. "+", ""):gsub(SPACE .. "+$", ""))
end

-- =============================================================================
-- Entities
-- =============================================================================

local NAMED = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	nbsp = " ",
	ensp = " ",
	emsp = " ",
	thinsp = " ",
	shy = "",
	zwj = "",
	zwnj = "",
	mdash = "—",
	ndash = "–",
	hellip = "…",
	lsquo = "‘",
	rsquo = "’",
	sbquo = "‚",
	ldquo = "“",
	rdquo = "”",
	bdquo = "„",
	laquo = "«",
	raquo = "»",
	copy = "©",
	reg = "®",
	trade = "™",
	times = "×",
	divide = "÷",
	middot = "·",
	bull = "•",
	deg = "°",
	plusmn = "±",
	le = "≤",
	ge = "≥",
	ne = "≠",
	asymp = "≈",
	rarr = "→",
	larr = "←",
	uarr = "↑",
	darr = "↓",
	harr = "↔",
	rArr = "⇒",
	lArr = "⇐",
	hArr = "⇔",
	euro = "€",
	pound = "£",
	yen = "¥",
	cent = "¢",
	sect = "§",
	para = "¶",
	check = "✓",
	cross = "✗",
	star = "☆",
	hearts = "♥",
	infin = "∞",
	minus = "−",
	prime = "′",
	Prime = "″",
	alpha = "α",
	beta = "β",
	gamma = "γ",
	delta = "δ",
	lambda = "λ",
	mu = "μ",
	pi = "π",
	sigma = "σ",
	theta = "θ",
	Delta = "Δ",
	Sigma = "Σ",
	Omega = "Ω",
}

local function utf8_char(n)
	if n < 0x80 then
		return string.char(n)
	elseif n < 0x800 then
		return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
	elseif n < 0x10000 then
		return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
	end
	return string.char(
		0xF0 + math.floor(n / 0x40000),
		0x80 + math.floor(n / 0x1000) % 0x40,
		0x80 + math.floor(n / 0x40) % 0x40,
		0x80 + n % 0x40
	)
end

local function entity(e)
	local n
	if e:match("^#[xX]%x+$") then
		n = tonumber(e:sub(3), 16)
	elseif e:match("^#%d+$") then
		n = tonumber(e:sub(2), 10)
	else
		return NAMED[e]
	end
	if not n or n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then
		return nil
	end
	if n == 0xA0 then
		return " "
	end
	return utf8_char(n)
end

local function decode(s)
	if not s:find("&", 1, true) then
		return s
	end
	return (s:gsub("&([#0-9A-Za-z]+);", entity))
end
M.decode = decode

-- =============================================================================
-- Parsing: a small tree, forgiving like a browser where pages need it
-- =============================================================================

local function parse(text)
	local root = { tag = "#root", children = {}, attrs = {} }
	local stack = { root }
	local low = lower(text)
	local n = #text
	local i = 1

	local function add(node)
		local top = stack[#stack]
		top.children[#top.children + 1] = node
	end
	local function truncate(k)
		for j = #stack, k + 1, -1 do
			stack[j] = nil
		end
	end
	-- close the nearest open `names` unless a `boundary` comes first
	local function close_open(names, boundary)
		for k = #stack, 2, -1 do
			local t = stack[k].tag
			if names[t] then
				truncate(k - 1)
				return
			end
			if boundary[t] then
				return
			end
		end
	end
	local LI, LISTS = set({ "li" }), set({ "ul", "ol" })
	local DTDD, DL = set({ "dt", "dd" }), set({ "dl" })
	local TR, TABLE = set({ "tr" }), set({ "table", "thead", "tbody", "tfoot" })
	local CELL, ROW = set({ "td", "th" }), set({ "tr", "table" })
	local SECTION, TBL = set({ "thead", "tbody", "tfoot" }), set({ "table" })
	local function implied(tag)
		if BLOCK[tag] then
			-- a block closes an open <p>
			for k = #stack, 2, -1 do
				local t = stack[k].tag
				if t == "p" then
					truncate(k - 1)
					break
				elseif BLOCK[t] then
					break
				end
			end
		end
		if tag == "li" then
			close_open(LI, LISTS)
		elseif tag == "dt" or tag == "dd" then
			close_open(DTDD, DL)
		elseif tag == "tr" then
			close_open(TR, TABLE)
		elseif tag == "td" or tag == "th" then
			close_open(CELL, ROW)
		elseif SECTION[tag] then
			close_open(SECTION, TBL)
		end
	end

	while i <= n do
		local lt = text:find("<", i, true)
		if not lt then
			add({ text = text:sub(i) })
			break
		end
		if lt > i then
			add({ text = text:sub(i, lt - 1) })
		end
		i = lt
		if text:sub(i, i + 3) == "<!--" then
			local e = text:find("-->", i + 4, true)
			i = e and e + 3 or n + 1
		elseif text:sub(i + 1, i + 1) == "!" or text:sub(i + 1, i + 1) == "?" then
			local e = text:find(">", i + 2, true)
			i = e and e + 1 or n + 1
		elseif text:sub(i + 1, i + 1) == "/" then
			local name = low:match("^([a-z][a-z0-9%-]*)", i + 2)
			local e = name and text:find(">", i + 2 + #name, true)
			if not e then
				add({ text = "<" })
				i = i + 1
			else
				i = e + 1
				if not VOID[name] then
					for k = #stack, 2, -1 do
						if stack[k].tag == name then
							truncate(k - 1)
							break
						end
					end
				end
			end
		else
			local name = low:match("^([a-z][a-z0-9%-]*)", i + 1)
			if not name then
				add({ text = "<" })
				i = i + 1
			else
				-- attributes up to the closing >, quotes respected
				local attrs, j, closed, self_closing = {}, i + 1 + #name, false, false
				while j <= n do
					local c = text:sub(j, j)
					if c:match(SPACE) then
						j = j + 1
					elseif c == ">" then
						closed = true
						j = j + 1
						break
					elseif c == "/" then
						if text:sub(j + 1, j + 1) == ">" then
							closed, self_closing = true, true
							j = j + 2
							break
						end
						j = j + 1
					else
						local key = low:match('^[^ \t\n\r\f\v/>="\']+', j)
						if not key then
							j = j + 1 -- a stray quote or =
						else
							j = j + #key
							local k = j
							while text:sub(k, k):match(SPACE) do
								k = k + 1
							end
							local value = ""
							if text:sub(k, k) == "=" then
								k = k + 1
								while text:sub(k, k):match(SPACE) do
									k = k + 1
								end
								local q = text:sub(k, k)
								if q == '"' or q == "'" then
									local e = text:find(q, k + 1, true)
									value = text:sub(k + 1, (e or n + 1) - 1)
									k = e and e + 1 or n + 1
								else
									value = text:match("^[^ \t\n\r\f\v>]*", k)
									k = k + #value
								end
								j = k
							end
							if attrs[key] == nil then
								attrs[key] = decode(value)
							end
						end
					end
				end
				if not closed then
					add({ text = "<" })
					i = i + 1
				else
					i = j
					implied(name)
					local node = { tag = name, attrs = attrs, children = {} }
					add(node)
					if RAW[name] then
						local e = low:find("</" .. name, i, true)
						node.children[1] = { text = text:sub(i, (e or n + 1) - 1), raw = true }
						if e then
							local gt = text:find(">", e, true)
							i = gt and gt + 1 or n + 1
						else
							i = n + 1
						end
					elseif not VOID[name] and not self_closing then
						stack[#stack + 1] = node
					end
				end
			end
		end
	end
	return root
end
M._parse = parse

-- =============================================================================
-- Text
-- =============================================================================

local function collapse(s)
	return (s:gsub(SPACE .. "+", " "))
end

local function find(node, tag)
	for _, c in ipairs(node.children or {}) do
		if c.tag == tag then
			return c
		end
		local f = c.children and find(c, tag)
		if f then
			return f
		end
	end
	return nil
end

-- every text below, as read (br: newline)
local function raw_text(node, out)
	out = out or {}
	for _, c in ipairs(node.children or {}) do
		if c.text then
			out[#out + 1] = c.text
		elseif c.tag == "br" then
			out[#out + 1] = "\n"
		else
			raw_text(c, out)
		end
	end
	return out
end

-- every text below, on one line
local function plain(node)
	return trim(collapse(decode(collapse(table.concat(raw_text(node))))))
end

local function wrap(inner, mark)
	local core = trim(inner)
	if core == "" then
		return inner
	end
	local lead = inner:match("^" .. SPACE) and " " or ""
	local trail = inner:match(SPACE .. "$") and " " or ""
	return lead .. mark .. core .. mark .. trail
end

-- a page's relative URL ("img/x.png", "../b.html") from the notes folder
-- ("z/html/img/x.png"), as a note's links are; others as they are
local function resolve_url(u, dir)
	local c = u:sub(1, 1)
	if u == "" or c == "/" or c == "#" or c == "?" or u:match("^[A-Za-z][A-Za-z0-9+.%-]*:") then
		return u
	end
	local path, rest = u:match("^([^?#]*)(.*)$")
	local parts = {}
	for p in dir:gmatch("[^/]+") do
		parts[#parts + 1] = p
	end
	for p in path:gmatch("[^/]+") do
		if p == ".." then
			if #parts == 0 then
				return u
			end
			parts[#parts] = nil
		elseif p ~= "." then
			parts[#parts + 1] = p
		end
	end
	local out = table.concat(parts, "/")
	if path:sub(-1) == "/" and out ~= "" then
		out = out .. "/"
	end
	return out .. rest
end

local dir_of = "" -- the page's folder, while converting

local function url_part(u)
	return (resolve_url(trim(u), dir_of):gsub(" ", "%%20"):gsub("%)", "%%29"))
end

local inline

local function inline_children(node)
	local out = {}
	for _, c in ipairs(node.children or {}) do
		out[#out + 1] = inline(c)
	end
	return table.concat(out)
end

inline = function(node)
	if node.text then
		return decode(collapse(node.text))
	end
	local tag = node.tag
	if DROP[tag] then
		return ""
	elseif tag == "br" then
		return "\n"
	elseif tag == "img" then
		local alt = trim(collapse(node.attrs.alt or ""))
		local src = url_part(node.attrs.src or "")
		if src == "" then
			return alt
		end
		return "![" .. alt .. "](" .. src .. ")"
	end
	local inner = inline_children(node)
	if tag == "strong" or tag == "b" then
		return wrap(inner, "**")
	elseif tag == "em" or tag == "i" then
		return wrap(inner, "*")
	elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
		return wrap(inner, "`")
	elseif tag == "a" then
		local href = url_part(node.attrs.href or "")
		local core = trim(collapse(inner:gsub("\n", " ")))
		if href == "" or href:sub(1, 1) == "#" or lower(href):match("^javascript:") or core == "" then
			return inner
		end
		local lead = inner:match("^" .. SPACE) and " " or ""
		local trail = inner:match(SPACE .. "$") and " " or ""
		if core == href then
			return lead .. href .. trail
		end
		return lead .. "[" .. core .. "](" .. href .. ")" .. trail
	end
	return inner
end

-- =============================================================================
-- Blocks
-- =============================================================================

local function writer()
	local w = { lines = {}, want_blank = false }
	function w.emit(ctx, line)
		if w.want_blank and #w.lines > 0 and w.lines[#w.lines] ~= "" then
			w.lines[#w.lines + 1] = ""
		end
		w.want_blank = false
		w.lines[#w.lines + 1] = ctx.prefix .. line
	end
	function w.blank(ctx)
		if not ctx.tight then
			w.want_blank = true
		end
	end
	return w
end

local function pieces(text)
	local out = {}
	for part in (text .. "\n"):gmatch("([^\n]*)\n") do
		local p = trim(part):gsub(" +", " ")
		if p ~= "" then
			out[#out + 1] = p
		end
	end
	return out
end

local function one_line(text)
	return (trim(text:gsub("\n", " ")):gsub(" +", " "))
end

local block, container, list

local function pre(w, node, ctx)
	local raw = decode(table.concat(raw_text(node))):gsub("\r\n", "\n"):gsub("\r", "\n")
	raw = raw:gsub("^\n", ""):gsub(SPACE .. "+$", "")
	local class = node.attrs.class or ""
	local code = find(node, "code")
	if code and code.attrs.class then
		class = class .. " " .. code.attrs.class
	end
	local lang = class:match("language%-([%w_+#.%-]+)") or class:match("lang%-([%w_+#.%-]+)") or ""
	local fence = raw:find("```", 1, true) and "````" or "```"
	w.blank(ctx)
	w.emit(ctx, fence .. lang)
	if raw ~= "" then
		for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
			w.emit(ctx, line)
		end
	end
	w.emit(ctx, fence)
	w.blank(ctx)
end

local function item(w, li, ctx, depth, marker)
	local indent = ("  "):rep(depth)
	local first = true
	local buf = {}
	local function out(text)
		for _, p in ipairs(pieces(text)) do
			if first then
				w.emit(ctx, indent .. marker .. " " .. p)
				first = false
			else
				w.emit(ctx, indent .. "  " .. p)
			end
		end
	end
	local function flush()
		out(table.concat(buf))
		buf = {}
	end
	local function head()
		if first then
			w.emit(ctx, indent .. marker)
			first = false
		end
	end
	for _, c in ipairs(li.children) do
		if c.text or not BLOCK[c.tag] then
			buf[#buf + 1] = inline(c)
		elseif c.tag == "ul" or c.tag == "ol" then
			flush()
			head()
			list(w, c, ctx, depth + 1)
		elseif c.tag == "pre" then
			flush()
			head()
			pre(w, c, { prefix = ctx.prefix .. indent .. "  ", tight = true })
		elseif not DROP[c.tag] then
			flush()
			out(inline(c))
		end
	end
	flush()
end

list = function(w, node, ctx, depth)
	if depth == 0 then
		w.blank(ctx)
	end
	local count = 0
	for _, c in ipairs(node.children) do
		if c.tag == "li" then
			count = count + 1
			item(w, c, ctx, depth, node.tag == "ol" and (count .. ".") or "-")
		elseif c.tag == "ul" or c.tag == "ol" then
			list(w, c, ctx, depth + 1)
		end
	end
	if depth == 0 then
		w.blank(ctx)
	end
end

local function rows_of(node, out)
	out = out or {}
	for _, c in ipairs(node.children) do
		if c.tag == "tr" then
			out[#out + 1] = c
		elseif c.tag == "thead" or c.tag == "tbody" or c.tag == "tfoot" then
			rows_of(c, out)
		end
	end
	return out
end

-- a note's table has no escape for "|" in a cell: "¦" reads as one
local function table_block(w, node, ctx)
	w.blank(ctx)
	local first = true
	for _, tr in ipairs(rows_of(node)) do
		local cells, heads = {}, true
		for _, c in ipairs(tr.children) do
			if c.tag == "td" or c.tag == "th" then
				cells[#cells + 1] = (one_line(inline(c)):gsub("|", "¦"))
				heads = heads and c.tag == "th"
			end
		end
		if #cells > 0 then
			w.emit(ctx, "| " .. table.concat(cells, " | ") .. " |")
			if first and heads then
				w.emit(ctx, "|" .. ("---|"):rep(#cells)) -- a header row
			end
			first = false
		end
	end
	w.blank(ctx)
end

block = function(w, node, ctx)
	local tag = node.tag
	local level = tag:match("^h([1-6])$")
	if DROP[tag] then
		return
	elseif level then
		local text = one_line(inline(node))
		if text ~= "" then
			w.blank(ctx)
			w.emit(ctx, ("#"):rep(tonumber(level)) .. " " .. text)
			w.blank(ctx)
		end
	elseif tag == "ul" or tag == "ol" then
		list(w, node, ctx, 0)
	elseif tag == "pre" then
		pre(w, node, ctx)
	elseif tag == "hr" then
		w.blank(ctx)
		w.emit(ctx, "---")
		w.blank(ctx)
	elseif tag == "table" then
		table_block(w, node, ctx)
	elseif tag == "blockquote" then
		w.blank(ctx)
		container(w, node, { prefix = ctx.prefix .. "> ", tight = true })
		w.blank(ctx)
	elseif tag == "dl" then
		w.blank(ctx)
		for _, c in ipairs(node.children) do
			if c.tag == "dt" or c.tag == "dd" then
				local lead = c.tag == "dt" and "- " or "  "
				for _, p in ipairs(pieces(inline(c))) do
					w.emit(ctx, lead .. p)
					lead = "  "
				end
			end
		end
		w.blank(ctx)
	else
		container(w, node, ctx)
	end
end

container = function(w, node, ctx)
	local buf = {}
	local function flush()
		local ps = pieces(table.concat(buf))
		buf = {}
		if #ps > 0 then
			w.blank(ctx)
			for _, p in ipairs(ps) do
				w.emit(ctx, p)
			end
			w.blank(ctx)
		end
	end
	for _, c in ipairs(node.children or {}) do
		if c.text or not BLOCK[c.tag] then
			buf[#buf + 1] = inline(c)
		else
			flush()
			block(w, c, ctx)
		end
	end
	flush()
end

-- =============================================================================
-- The note
-- =============================================================================

--- "/raw/" + the path, with what a URL can't hold escaped
function M.raw_url(rel)
	return "/raw/" .. rel:gsub("[^A-Za-z0-9._~/%-]", function(c)
		return string.format("%%%02X", c:byte())
	end)
end

local function stem_of(rel)
	local name = rel:match("([^/]+)$") or rel
	return name:match("^(.+)%.[^.]+$") or name
end

--- The page `text` (from the notes folder's `rel`) as a note's lines.
---@param text string
---@param rel string
---@return string[]
function M.convert(text, rel)
	text = text:gsub("^\239\187\191", "")
	local root = parse(text)
	local stem = stem_of(rel)
	dir_of = rel:match("^(.*)/[^/]*$") or ""
	local title_node = find(root, "title")
	local title = title_node and plain(title_node) or ""
	if title == "" then
		local h1 = find(root, "h1")
		title = h1 and plain(h1) or ""
	end
	if title == "" then
		title = stem
	end
	local lines = { "@@" .. title }
	if lower(stem) ~= lower(title) then
		lines[#lines + 1] = "@@" .. stem
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "From [" .. rel .. "](" .. M.raw_url(rel) .. ")"
	lines[#lines + 1] = ""

	local w = writer()
	container(w, find(root, "body") or root, { prefix = "" })
	local body = w.lines
	local s, e = 1, #body
	while s <= e and body[s] == "" do
		s = s + 1
	end
	while e >= s and body[e] == "" do
		e = e - 1
	end
	for k = s, e do
		lines[#lines + 1] = body[k]
	end
	return lines
end

return M
