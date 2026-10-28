-- features/highlights.lua - Syntax highlighting and conceal for Zortex
--
-- Highlights are painted from the document's syntax (core/syntax via
-- core/document), not from patterns of their own: every line already says
-- what it is (heading, label, item with checkbox, table row, ...) and where
-- its inline spans are (links, attributes, code, math, bold, ...). Only a few
-- purely visual decorations (operators, punctuation, quotes, percentages) are
-- matched here, and never inside a span.
local M = {}

local Document = require("zortex.core.document")

local NS = vim.api.nvim_create_namespace("zortex_highlights")

-- =============================================================================
-- Highlight groups
-- =============================================================================

-- By default every group links to (or is derived from) a standard group, so
-- the colorscheme decides the look and a colorscheme's own Zortex* groups
-- win. ui.highlights = { preset = "rose-pine" } gives a Rose Pine Moon palette;
-- ui.highlights.groups overrides single groups ({ fg = "#..." } or { link = ... }).

-- name -> standard group, or { from = group, <attrs to add> }
local LINKS = {
	ZortexHeading1 = { from = "Title", bold = true },
	ZortexHeading2 = { from = "Title", bold = true },
	ZortexHeading3 = { from = "Title", bold = true },
	ZortexBullet1 = "Special",
	ZortexBullet2 = "Identifier",
	ZortexBullet3 = "Constant",
	ZortexBullet4 = "Comment",
	ZortexCodeBlock = "String",
	ZortexArticle = { from = "Title", bold = true },
	ZortexTag = "Label",
	ZortexBoldHeading = { from = "Function", bold = true },
	ZortexLabel = { from = "Identifier", bold = true },
	ZortexLabelText = "Normal",
	ZortexLabelList = "Identifier",
	ZortexLabelListText = "Normal",
	ZortexNumberList = { from = "Special", bold = true },
	ZortexTextList = { from = "Special", bold = true },
	ZortexTaskCheckbox = "Special",
	ZortexTaskText = "Normal",
	ZortexTaskDone = { from = "Comment", strikethrough = true },
	ZortexMarkdownLink = "Underlined",
	ZortexLink = "Underlined",
	-- a link takes the look of what it names (core/link.kind)
	ZortexLinkNote = "ZortexLink",
	ZortexLinkHeading = { from = "Title", underline = true, bold = false },
	ZortexLinkLabel = { from = "Identifier", underline = true, bold = false },
	ZortexLinkBold = { from = "Function", underline = true, bold = false },
	ZortexLinkItem = { from = "Special", underline = true, bold = false },
	ZortexTagSearchAt = "Comment", -- the "@" of @[tags]
	-- the "›" shown for a link's "/" (ui.highlights.link_separator), and the
	-- link icon; ui.highlights.groups.ZortexLinkDelimiter changes its look
	ZortexLinkDelimiter = "Comment",
	ZortexFootnote = { from = "Comment", italic = true },
	ZortexURL = "Underlined",
	ZortexBold = { bold = true },
	ZortexItalic = { italic = true },
	ZortexCodeInline = "String",
	ZortexMathInline = { from = "Special", italic = true },
	ZortexMathBlock = { from = "Special", italic = true },
	ZortexAttribute = { from = "Comment", italic = true },
	ZortexObjective = { from = "Title", bold = true },
	ZortexKeyResult = { from = "Identifier", bold = true },
	ZortexKeyResultCheckbox = "Special",
	ZortexKeyResultText = "Normal",
	ZortexKeyResultDone = { from = "Comment", strikethrough = true },
	ZortexTime = "Number",
	ZortexPercent = "Number",
	ZortexOperator = "Operator",
	ZortexPunctuation = "Delimiter",
	ZortexBlockQuote = "Comment",
	ZortexQuote = { from = "String", italic = true },
	ZortexTableSeparator = { from = "Delimiter", bold = true },
	ZortexTableBorder = "NonText",
	ZortexRule = "NonText",
}

local function default_groups()
	local out = {}
	for name, spec in pairs(LINKS) do
		if type(spec) == "string" then
			out[name] = { link = spec }
		elseif spec.from then
			local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = spec.from, link = false })
			local hl = ok and vim.deepcopy(base) or {}
			for k, v in pairs(spec) do
				if k ~= "from" then
					hl[k] = v
				end
			end
			out[name] = hl
		else
			out[name] = vim.deepcopy(spec)
		end
	end
	return out
end

-- A Rose Pine Moon palette: ui.highlights = { preset = "rose-pine" }
local ROSE_PINE = {
	ZortexHeading1 = { bold = true, italic = true, fg = "#eb6f92", bg = "#2a273f" },
	ZortexHeading2 = { bold = true, italic = true, fg = "#ea9a97", bg = "#232136" },
	ZortexHeading3 = { bold = true, italic = true, fg = "#f6c177", bg = "#1e1c1f" },
	ZortexBullet1 = { fg = "#3e8fb0" },
	ZortexBullet2 = { fg = "#9ccfd8" },
	ZortexBullet3 = { fg = "#c4a7e7" },
	ZortexBullet4 = { fg = "#908caa" },
	ZortexCodeBlock = { fg = "#f2ae49", bg = "#1e1c1f" },
	ZortexArticle = { bold = true, fg = "#c4a7e7" },
	ZortexTag = { fg = "#ea9a97" },
	ZortexBoldHeading = { bold = true, fg = "#56949f" },
	ZortexLabel = { bold = true, fg = "#3e8fb0" },
	ZortexLabelText = { bold = true, fg = "#f6c177" },
	ZortexLabelList = { bold = false, fg = "#3e8fb0" },
	ZortexLabelListText = { bold = false, fg = "#f6c177" },
	ZortexNumberList = { fg = "#3e8fb0", bold = true },
	ZortexTextList = { fg = "#3e8fb0", bold = true },
	ZortexTaskCheckbox = { fg = "#ea9a97" },
	ZortexTaskText = { fg = "#f6c177" },
	ZortexTaskDone = { fg = "#908caa", strikethrough = true },
	ZortexMarkdownLink = { fg = "#3e8fb0", underline = true },
	ZortexLink = { fg = "#3e8fb0", underline = true },
	ZortexLinkNote = { fg = "#c4a7e7", underline = true },
	ZortexLinkHeading = { fg = "#ea9a97", underline = true },
	ZortexLinkLabel = { fg = "#3e8fb0", underline = true },
	ZortexLinkBold = { fg = "#56949f", underline = true },
	ZortexLinkItem = { fg = "#9ccfd8", underline = true },
	ZortexTagSearchAt = { fg = "#6e6a86" },
	ZortexLinkDelimiter = { fg = "#6e6a86" },
	ZortexFootnote = { fg = "#9ccfd8", italic = true },
	ZortexURL = { fg = "#3e8fb0", underline = true },
	ZortexBold = { bold = true },
	ZortexItalic = { italic = true },
	ZortexCodeInline = { fg = "#f2ae49", bg = "#2d2a2e" },
	ZortexMathInline = { fg = "#a9d977", italic = true },
	ZortexMathBlock = { fg = "#a9d977", italic = true },
	ZortexAttribute = { fg = "#908caa", italic = true },
	ZortexObjective = { fg = "#ebbcba", bold = true },
	ZortexKeyResult = { fg = "#c4a7e7", bold = true },
	ZortexKeyResultCheckbox = { fg = "#ea9a97" },
	ZortexKeyResultText = { fg = "#f6c177" },
	ZortexKeyResultDone = { fg = "#908caa", strikethrough = true },
	ZortexTime = { fg = "#f6c177" },
	ZortexPercent = { fg = "#9ccfd8" },
	ZortexOperator = { fg = "#ea9a97" },
	ZortexPunctuation = { fg = "#ea9a97" },
	ZortexBlockQuote = { fg = "#908caa" },
	ZortexQuote = { fg = "#c4a7e7", italic = true },
	ZortexTableSeparator = { fg = "#908caa", bold = true },
	ZortexTableBorder = { fg = "#524f67" },
	ZortexRule = { fg = "#524f67" },
}

local PRESETS = { ["rose-pine"] = ROSE_PINE }

function M.setup_highlights()
	local cfg = (require("zortex.config").ui or {}).highlights or {}
	local preset = cfg.preset and PRESETS[cfg.preset]
	local groups = preset and vim.deepcopy(preset) or default_groups()
	for name, opts in pairs(cfg.groups or {}) do
		groups[name] = opts
	end
	for name, opts in pairs(groups) do
		opts = vim.deepcopy(opts)
		-- defaults yield to a colorscheme's own Zortex* groups; a preset and
		-- your overrides don't
		if not preset and not (cfg.groups or {})[name] then
			opts.default = true
		end
		vim.api.nvim_set_hl(0, name, opts)
	end
	-- The band behind a heading line: only its background, so what isn't
	-- the title (its @attributes) keeps its own look rather than turning
	-- bold and heading-coloured
	for n = 1, 3 do
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "ZortexHeading" .. n, link = false })
		vim.api.nvim_set_hl(0, "ZortexHeading" .. n .. "Line", { bg = ok and hl.bg or nil, default = true })
	end
end

-- =============================================================================
-- Painting helpers
-- =============================================================================

local BULLETS = { "•", "◦", "▸", "▹" }
local LINK_ICON = "🔗"

local function paint(buf, row, group, s, e)
	if s and e and e > s then
		vim.api.nvim_buf_add_highlight(buf, NS, group, row, s, e)
	end
end

-- Every mark covers the text it decorates and is invalidated with it: a
-- deleted or moved line takes its marks along instead of leaving them piled
-- on the next line until the next repaint
local function mark(buf, row, col, opts)
	opts.invalidate = true
	opts.undo_restore = false
	if not opts.end_col then
		-- a point mark (an overlay, a line highlight): give it the character
		-- under it, so it has a range to lose; its conceal stays a no-op
		opts.end_col = math.min(col + 1, #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""))
		opts.conceal = nil
	end
	vim.api.nvim_buf_set_extmark(buf, NS, row, col, opts)
end

local function conceal(buf, row, s, e)
	mark(buf, row, s, { end_col = e, conceal = "" })
end

local function overlay(buf, row, col, text, group, conceal_char)
	mark(buf, row, col, {
		virt_text = { { text, group } },
		virt_text_pos = "overlay",
		conceal = conceal_char,
	})
end

-- the link icon replaces the opening "[" (concealed with it)
local function icon(buf, row, col)
	mark(buf, row, col, {
		end_col = col + 1,
		conceal = "",
		virt_text = { { LINK_ICON, "ZortexLinkDelimiter" } },
		virt_text_pos = "inline",
	})
end

-- =============================================================================
-- Inline spans
-- =============================================================================

local LINK_GROUPS = {
	note = "ZortexLinkNote",
	heading = "ZortexLinkHeading",
	label = "ZortexLinkLabel",
	bold = "ZortexLinkBold",
	item = "ZortexLinkItem",
}

-- A link is coloured once, by what it names; a tag search, a query or a
-- follow link keeps ZortexLink
local function link_group(span_type, definition)
	if span_type == "tag_search" or not definition then
		return "ZortexLink"
	end
	return LINK_GROUPS[require("zortex.core.link").kind(definition) or ""] or "ZortexLink"
end

-- The "/" between a link's parts, shown as ui.highlights.link_separator
-- ("›"; false or "/" keeps the "/"), coloured ZortexLinkDelimiter either
-- way: each top-level "/" of the definition from byte `s` to `e` (0-based,
-- end exclusive), not a leading "/" (a link in this note) or "~/" (the notes
-- folder), nor one inside parentheses ("@(a/b)"). Above the link's own
-- colour (painted over the whole definition by nvim_buf_add_highlight, at
-- the extmark default 4096), so the group shows.
local SEPARATOR_PRIORITY = 4096 + 10
local function separators(buf, row, line, s, e)
	local sep = ((require("zortex.config").ui or {}).highlights or {}).link_separator
	if sep == nil then
		sep = "›"
	end
	if not sep or sep == "" then
		sep = "/"
	end
	local depth, first = 0, s
	if line:sub(s + 1, s + 2) == "~/" then
		first = s + 2
	elseif line:sub(s + 1, s + 1) == "/" then
		first = s + 1
	end
	for i = first, e - 1 do
		local c = line:sub(i + 1, i + 1)
		if c == "(" then
			depth = depth + 1
		elseif c == ")" then
			depth = math.max(0, depth - 1)
		elseif c == "/" and depth == 0 then
			mark(buf, row, i, {
				end_col = i + 1,
				conceal = sep ~= "/" and sep or nil,
				hl_group = "ZortexLinkDelimiter",
				priority = SEPARATOR_PRIORITY,
			})
		end
	end
end

local function paint_spans(buf, row, spans, kind, line)
	for _, span in ipairs(spans) do
		local t, s, e = span.type, span.s, span.e
		if t == "link" or t == "live_link" or t == "tag_search" then
			-- "[" ... "]" (after "!" or "@" for live links and tag searches)
			local open = t == "link" and s or s + 1
			if t == "tag_search" then
				paint(buf, row, "ZortexTagSearchAt", s, s + 1)
			end
			if span.text then
				-- [text](P/#1.4): the text, coloured as the link; "](…)" hidden
				local text_e = span.def_s - 2
				paint(buf, row, link_group(t, span.definition), open + 1, text_e)
				icon(buf, row, open)
				conceal(buf, row, text_e, e)
			else
				paint(buf, row, link_group(t, span.definition), open + 1, e - 1)
				icon(buf, row, open)
				conceal(buf, row, e - 1, e)
				if t ~= "tag_search" and line then
					separators(buf, row, line, open + 1, e - 1)
				end
			end
		elseif t == "markdown" then
			paint(buf, row, "ZortexMarkdownLink", s + 1, s + 1 + #span.text)
			icon(buf, row, s)
			conceal(buf, row, s + 1 + #span.text, e)
		elseif t == "footnote_ref" then
			paint(buf, row, "ZortexFootnote", s, e)
		elseif t == "url" then
			paint(buf, row, "ZortexURL", s, e)
		elseif t == "bold" or t == "italic" then
			paint(buf, row, t == "bold" and "ZortexBold" or "ZortexItalic", s, e)
			conceal(buf, row, s, span.inner_s)
			conceal(buf, row, span.inner_e, e)
			paint_spans(buf, row, span.children or {}, kind, line)
		elseif t == "code" then
			paint(buf, row, "ZortexCodeInline", s, e)
		elseif t == "math" then
			paint(buf, row, span.display and "ZortexMathBlock" or "ZortexMathInline", s, e)
		elseif t == "attribute" then
			-- on any line: tags (@rust) end text lines and quotes too
			paint(buf, row, "ZortexAttribute", s, e)
		elseif t == "time" then
			paint(buf, row, "ZortexTime", s, e)
		end
	end
end

-- Visual-only decorations, skipped inside spans
local DECORATIONS = {
	{ "%d+%%", "ZortexPercent" },
	{ "%s()→()%s", "ZortexOperator" },
	{ "%s():=()%s", "ZortexOperator" },
	{ "%s()<%->()%s", "ZortexOperator" },
	{ "%s()%->()%s", "ZortexOperator" },
	{ "%s()<%-()%s", "ZortexOperator" },
	{ "%s()=>()%s", "ZortexOperator" },
	{ "%s()~>()%s", "ZortexOperator" },
	{ "%s()!=()%s", "ZortexOperator" },
	{ "%s()%+()%s", "ZortexOperator" },
	{ "%s()vs%.()%s", "ZortexOperator" },
	{ "()[%.;,%?]()%s", "ZortexPunctuation" },
	{ "()[%.%?]()$", "ZortexPunctuation" },
	{ '"[^"]*"', "ZortexQuote" },
}

local function covered(spans, s, e)
	for _, span in ipairs(spans) do
		if s < span.e and e > span.s then
			return true
		end
	end
	return false
end

local function paint_decorations(buf, row, line, spans, from)
	for _, deco in ipairs(DECORATIONS) do
		local pattern, group = deco[1], deco[2]
		local init = from + 1
		while true do
			local ms, me, cs, ce = line:find(pattern, init)
			if not ms then
				break
			end
			local s, e
			if cs then
				s, e = cs - 1, ce - 1 -- position captures: the operator itself
			else
				s, e = ms - 1, me
			end
			if e > s and not covered(spans, s, e) then
				paint(buf, row, group, s, e)
			end
			init = math.max(me, ms) + 1
		end
	end
end

-- =============================================================================
-- Lines
-- =============================================================================

local function bullet_level(indent)
	return math.min(math.floor(indent / 2) + 1, #BULLETS)
end

local function paint_item(buf, row, line, d, it)
	local is_kr = it.key and it.key:match("^KR%d+$")

	-- Marker
	if it.marker_type == "bullet" then
		local level = bullet_level(d.indent)
		local group = "ZortexBullet" .. level
		paint(buf, row, group, 0, it.marker_col + 1)
		overlay(buf, row, it.marker_col, BULLETS[level], group, "")
	elseif it.marker_type == "ordered" then
		local group = it.marker:match("^%d") and "ZortexNumberList" or "ZortexTextList"
		paint(buf, row, group, 0, it.marker_col + #it.marker)
	elseif it.marker_type == "time" then
		for ts, te in it.marker:gmatch("()%d%d?:%d%d()") do
			paint(buf, row, "ZortexTime", it.marker_col + ts - 1, it.marker_col + te - 1)
		end
	end

	-- Key ("KR1:", "Label:")
	if it.key then
		if is_kr then
			paint(buf, row, "ZortexKeyResult", it.key_col, it.key_col + #it.key + 1)
		else
			paint(buf, row, "ZortexLabelListText", 0, it.key_col + #it.key + 1)
		end
	end

	-- Checkbox and task text
	if it.mark then
		local prefix = is_kr and "ZortexKeyResult" or "ZortexTask"
		paint(buf, row, prefix .. "Checkbox", it.mark_col, it.mark_col + 3)
		if it.mark == " " then
			mark(buf, row, it.mark_col + 1, {
				virt_text = { { " ", "ZortexTaskCheckbox" } },
				virt_text_pos = "overlay",
				conceal = " ",
			})
		end
		local done = it.mark == "x" or it.mark == "X"
		local text_group = is_kr and (done and "ZortexKeyResultDone" or "ZortexKeyResultText")
			or (done and "ZortexTaskDone" or "ZortexTaskText")
		paint(buf, row, text_group, it.content_col, #line)
	end
end

local function paint_line(buf, row, line, d, spans)
	local kind = d.kind
	if kind == "code" or kind == "fence" then
		paint(buf, row, "ZortexCodeBlock", 0, #line)
		return
	elseif kind == "math" or kind == "math_fence" then
		paint(buf, row, "ZortexMathBlock", 0, #line)
		return
	elseif kind == "blank" then
		return
	end

	if kind == "article" then
		paint(buf, row, "ZortexArticle", 0, #line)
	elseif kind == "tag" then
		paint(buf, row, "ZortexTag", 0, #line)
	elseif kind == "heading" then
		-- the title in the heading's colours; its @attributes like those on
		-- any line (ZortexAttribute, from paint_spans)
		local level = math.min(d.heading, 3)
		local group = "ZortexHeading" .. level
		local from = 0
		local function title(s, e) -- the text between attributes, not the spaces
			if line:sub(s + 1, e):find("%S") then
				paint(buf, row, group, s, e)
			end
		end
		for _, span in ipairs(spans) do
			if span.type == "attribute" then
				title(from, span.s)
				from = span.e
			end
		end
		title(from, #line)
		mark(buf, row, 0, { line_hl_group = group .. "Line" })
		-- Objective ids: "## 3M-2026-Q1 Title"
		local caps = { line:match("^##%s+()(%d+[MY])()%-()(%d+)()%-()(%w%d)()") }
		for i = 1, #caps, 3 do
			paint(buf, row, "ZortexObjective", caps[i] - 1, caps[i + 2] - 1)
		end
	elseif kind == "bold_heading" then
		-- "**Title:**": content_end is the colon, which stays visible
		paint(buf, row, "ZortexBoldHeading", d.content_col, d.content_end + 1)
		conceal(buf, row, 0, 2)
		conceal(buf, row, d.content_end + 1, d.content_end + 3)
	elseif kind == "label" then
		-- "Label:", or "*A longer label:*" (its stars hidden by the italic span)
		local colon = (line:find(":%*?$") or #line) - 1
		if d.item then
			paint_item(buf, row, line, d, d.item)
			paint(buf, row, "ZortexLabelList", 0, colon + 1)
		else
			paint(buf, row, "ZortexLabel", 0, colon)
		end
	elseif kind == "item" then
		paint_item(buf, row, line, d, d.item)
	elseif kind == "text" and d.key then
		paint(buf, row, "ZortexLabelText", 0, d.key_col + #d.key + 1)
	elseif kind == "table" then
		if d.separator then
			paint(buf, row, "ZortexTableSeparator", 0, #line)
		else
			for col in line:gmatch("()|") do
				paint(buf, row, "ZortexTableBorder", col - 1, col)
			end
		end
	elseif kind == "quote" then
		paint(buf, row, "ZortexBlockQuote", 0, #line)
	elseif kind == "rule" then
		-- "---" drawn as a line across the text width
		local width = vim.bo[buf].textwidth > 0 and vim.bo[buf].textwidth or 72
		overlay(buf, row, 0, string.rep("─", math.max(width, #line)), "ZortexRule")
	elseif kind == "footnote" then
		paint(buf, row, "ZortexFootnote", 0, #line:match("^%[%^[^%]]+%]"))
	end

	paint_spans(buf, row, spans, kind, line)
	if kind ~= "article" and kind ~= "tag" then
		paint_decorations(buf, row, line, spans, d.content_col or 0)
	end
end

--- Repaint a buffer from its document syntax.
function M.highlight_buffer(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	local doc = Document.from_buffer(bufnr)
	if not doc then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	for lnum, d in ipairs(doc.syntax.lines) do
		local ok, err = pcall(paint_line, bufnr, lnum - 1, doc.lines[lnum], d, doc:inline(lnum))
		if not ok then
			require("zortex.core.logger").debug("highlights", "line failed", { lnum = lnum, err = err })
		end
	end
end

-- Buffers changed while not current (a :ZortexMove target, a calendar
-- toggle, an edit through the API) get no TextChanged: repaint them shortly
-- after any change. The current buffer in insert mode waits for InsertLeave.
local watched, pending = {}, {}

function M.watch(bufnr)
	if watched[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	watched[bufnr] = true
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, buf)
			if pending[buf] then
				return
			end
			pending[buf] = true
			vim.defer_fn(function()
				pending[buf] = nil
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				if buf == vim.api.nvim_get_current_buf() and vim.fn.mode():match("^[iR]") then
					return
				end
				M.highlight_buffer(buf)
			end, 30)
		end,
		on_detach = function(_, buf)
			watched[buf], pending[buf] = nil, nil
		end,
	})
end

-- =============================================================================
-- Fold text
-- =============================================================================

function M.zortex_fold_text()
	local start_line = vim.fn.getline(vim.v.foldstart)
	local fold_count = " ⋯ (" .. (vim.v.foldend - vim.v.foldstart + 1) .. " lines)"

	local doc = Document.from_buffer(0)
	local d = doc:info(vim.v.foldstart) or {}
	local hl_group = "Normal"
	if d.kind == "heading" then
		hl_group = "ZortexHeading" .. math.min(d.heading, 3)
	elseif d.kind == "label" then
		hl_group = d.item and "ZortexLabelList" or "ZortexLabel"
	elseif d.kind == "bold_heading" then
		hl_group = "ZortexBoldHeading"
	end

	-- First non-empty line inside the fold, as a preview
	local preview_text = ""
	for i = vim.v.foldstart + 1, vim.v.foldend do
		local trimmed = vim.fn.getline(i):gsub("^%s+", "")
		if trimmed ~= "" then
			preview_text = " → " .. trimmed
			break
		end
	end

	-- a heading's @attributes as on any line, not in the heading's colours
	local chunks, from = {}, 1
	if d.kind == "heading" then
		for _, span in ipairs(doc:inline(vim.v.foldstart) or {}) do
			if span.type == "attribute" then
				chunks[#chunks + 1] = { start_line:sub(from, span.s), hl_group }
				chunks[#chunks + 1] = { start_line:sub(span.s + 1, span.e), "ZortexAttribute" }
				from = span.e + 1
			end
		end
	end
	chunks[#chunks + 1] = { start_line:sub(from), hl_group }
	chunks[#chunks + 1] = { preview_text, "Comment" }
	chunks[#chunks + 1] = { fold_count, "NonText" }
	return vim.tbl_filter(function(c)
		return c[1] ~= ""
	end, chunks)
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup()
	M.setup_autocmd()
	M.setup_highlights()
end

function M.setup_autocmd()
	local group = vim.api.nvim_create_augroup("ZortexHighlights", { clear = true })

	-- :colorscheme clears every group; define ours again
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			M.setup_highlights()
		end,
	})

	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = group,
		pattern = "*.zortex",
		callback = function()
			vim.wo.foldtext = "v:lua.require('zortex.features.highlights').zortex_fold_text()"
			vim.wo.conceallevel = 2
			vim.wo.concealcursor = ""
		end,
	})

	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile", "TextChanged", "InsertLeave" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			M.highlight_buffer(args.buf)
			M.watch(args.buf)
		end,
	})
end

return M
