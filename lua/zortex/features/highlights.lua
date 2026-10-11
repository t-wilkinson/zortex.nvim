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

local GROUPS = {
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
}

function M.setup_highlights()
	for name, opts in pairs(GROUPS) do
		vim.api.nvim_set_hl(0, name, opts)
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

local function conceal(buf, row, s, e)
	vim.api.nvim_buf_set_extmark(buf, NS, row, s, { end_col = e, conceal = "" })
end

local function overlay(buf, row, col, text, group, conceal_char)
	vim.api.nvim_buf_set_extmark(buf, NS, row, col, {
		virt_text = { { text, group } },
		virt_text_pos = "overlay",
		conceal = conceal_char,
	})
end

local function icon(buf, row, col)
	vim.api.nvim_buf_set_extmark(buf, NS, row, col, {
		virt_text = { { LINK_ICON, "ZortexLinkDelimiter" } },
		virt_text_pos = "inline",
	})
end

-- =============================================================================
-- Inline spans
-- =============================================================================

local ATTRIBUTE_KINDS = { heading = true, item = true, label = true, bold_heading = true }

local function paint_spans(buf, row, spans, kind)
	for _, span in ipairs(spans) do
		local t, s, e = span.type, span.s, span.e
		if t == "link" or t == "live_link" or t == "tag_search" then
			-- "[" ... "]" (after "!" or "@" for live links and tag searches)
			local open = t == "link" and s or s + 1
			paint(buf, row, "ZortexLink", open + 1, e - 1)
			conceal(buf, row, open, open + 1)
			icon(buf, row, open)
			conceal(buf, row, e - 1, e)
		elseif t == "markdown" then
			paint(buf, row, "ZortexMarkdownLink", s + 1, s + 1 + #span.text)
			conceal(buf, row, s, s + 1)
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
			paint_spans(buf, row, span.children or {}, kind)
		elseif t == "code" then
			paint(buf, row, "ZortexCodeInline", s, e)
		elseif t == "math" then
			paint(buf, row, span.display and "ZortexMathBlock" or "ZortexMathInline", s, e)
		elseif t == "attribute" then
			if ATTRIBUTE_KINDS[kind] then
				paint(buf, row, "ZortexAttribute", s, e)
			end
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
			vim.api.nvim_buf_set_extmark(buf, NS, row, it.mark_col + 1, {
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
		local group = "ZortexHeading" .. math.min(d.heading, 3)
		paint(buf, row, group, 0, #line)
		vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { line_hl_group = group })
		-- Objective ids: "## 3M-2026-Q1 Title"
		local caps = { line:match("^##%s+()(%d+[MY])()%-()(%d+)()%-()(%w%d)()") }
		for i = 1, #caps, 3 do
			paint(buf, row, "ZortexObjective", caps[i] - 1, caps[i + 2] - 1)
		end
	elseif kind == "bold_heading" then
		paint(buf, row, "ZortexBoldHeading", d.content_col, d.content_end)
		conceal(buf, row, 0, 2)
		conceal(buf, row, d.content_end, d.content_end + 2)
	elseif kind == "label" then
		local colon = #line - 1
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
	elseif kind == "footnote" then
		paint(buf, row, "ZortexFootnote", 0, #line:match("^%[%^[^%]]+%]"))
	end

	paint_spans(buf, row, spans, kind)
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

-- =============================================================================
-- Fold text
-- =============================================================================

function M.zortex_fold_text()
	local start_line = vim.fn.getline(vim.v.foldstart)
	local fold_count = " ⋯ (" .. (vim.v.foldend - vim.v.foldstart + 1) .. " lines)"

	local d = Document.from_buffer(0):info(vim.v.foldstart) or {}
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

	return {
		{ start_line, hl_group },
		{ preview_text, "Comment" },
		{ fold_count, "NonText" },
	}
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
		end,
	})
end

return M
