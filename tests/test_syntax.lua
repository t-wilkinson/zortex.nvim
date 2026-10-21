local T = require("helpers")
local syntax = require("zortex.core.syntax")
local Item = require("zortex.core.item")

local function sample()
	return vim.fn.readfile(T.root .. "/tests/fixtures/syntax/sample.zortex")
end

local function find(lines, text)
	for i, l in ipairs(lines) do
		if l == text then
			return i
		end
	end
	error("line not found: " .. text)
end

T.test("line kinds and structure", function()
	local lines = sample()
	local ast = syntax.parse(lines)
	local kind = function(text)
		return ast.lines[find(lines, text)]
	end
	T.eq(ast.header.names, { "Syntax sample", "Sample" })
	T.eq(ast.header.tags, { "Example", "size(lg)" })
	T.eq(kind("# Heading one @p1 @a(4.1)").text, "Heading one")
	T.eq(kind("**Bold heading:**").kind, "bold_heading")
	T.eq(kind("  Indented label:").level, 10)
	local bl = kind("- Bulleted label:")
	T.eq({ bl.kind, bl.text, bl.item.marker }, { "label", "Bulleted label", "-" })
	T.eq(kind("# not a heading").kind, "code") -- inside a fence
	T.eq(kind("- [ ] not a task").kind, "code")
	T.eq(kind("\\int_0^1 x\\,dx").kind, "math")
	T.eq(kind("|-------|-------|").separator, true)
	T.eq(kind("> a quote").kind, "quote")
	T.eq(kind("| not a quote").kind, "text")
	T.eq(kind("+ not a bullet").kind, "text")
	T.eq(kind("[^1]: The footnote with https://example.com and ./images/pic.png").kind, "footnote")
	T.eq(kind("Key: value text with @home and an email me@example.com.").key, "Key")

	local types = vim.tbl_map(function(s)
		return s.type .. ":" .. s.text
	end, ast.sections)
	T.eq(types, {
		"article:Syntax sample",
		"heading:Heading one",
		"bold_heading:Bold heading",
		"label:Label",
		"label:Indented label",
		"label:Bulleted label",
		"heading:3M-2026-Q1 Objective title",
		"heading:Tasks",
	})
	T.eq(vim.tbl_map(function(b)
		return b.kind
	end, ast.blocks), { "table", "code", "math" })
end)

T.test("list items: markers, keys, checkboxes, times", function()
	local it = syntax.item("- KR1: [ ] Key result [P/#1 Programming]")
	T.eq({ it.marker, it.key, it.mark, it.key_col, it.mark_col }, { "-", "KR1", " ", 2, 7 })
	it = syntax.item("16:00 - 17:00 Ranged entry")
	T.eq({ it.marker_type, it.time.from, it.time.to, it.content_col }, { "time", "16:00", "17:00", 14 })
	it = syntax.item("  - [x] Nested")
	T.eq({ it.marker_col, it.mark, it.content_col }, { 2, "x", 8 })
	T.eq(syntax.item("B. lettered").marker_type, "ordered")
	T.eq(syntax.item("**bold** text"), nil)
	T.eq(syntax.item("-5 degrees"), nil)
	T.eq(syntax.item("- [ ]").mark, nil) -- a checkbox needs text
end)

T.test("inline spans", function()
	local line = "See @[cars parts], ![Live] and [text](https://x.io) at 10:30, me@x.com @p1 **b [L]**"
	local spans = syntax.inline(line)
	local got = vim.tbl_map(function(s)
		return s.type .. "=" .. line:sub(s.s + 1, s.e)
	end, spans)
	T.eq(got, {
		"tag_search=@[cars parts]",
		"live_link=![Live]",
		"markdown=[text](https://x.io)",
		"time=10:30",
		"attribute=@p1",
		"bold=**b [L]**",
	})
	T.eq(spans[1].content, "cars parts")
	T.eq(spans[#spans].children[1].definition, "L")
	-- checkboxes and footnotes are not links; "$5 and $6" is not math
	T.eq(#syntax.links("- [x] done [^1] costs $5 and $6"), 0)
	T.eq(#syntax.inline("costs $5 and $6"), 0)
end)

T.test("link.at keeps its result shape", function()
	local link = require("zortex.core.link")
	local line = "go to [P/#1.4 - zortex] or https://x.io or [^2] @a(4.1)"
	local l = link.at(line, 8)
	T.eq({ l.type, l.definition, l.full_match_text, l.col }, { "link", "P/#1.4 - zortex", "[P/#1.4 - zortex]", 7 })
	T.eq(link.at(line, 30).type, "website")
	T.eq(link.at(line, line:find("%[%^") + 1).type, "footnote")
	local area = link.at(line, #line - 2)
	T.eq({ area.type, area.definition }, { "link", "Areas/#4.1" })
	T.eq(link.at(line, 2), nil)
end)

T.test("items: tasks, key results, calendar entries share one type", function()
	local task = Item.task("  - [ ] Call mom @home @p1 @size(sm)")
	T.eq({ task.text, task.completed, task.attributes.size, task.attributes.p, task.indent }, { "Call mom", false, "sm", "1", 2 })
	T.eq(task:with_mark("x"), "  - [x] Call mom @home @p1 @size(sm)")
	T.eq(Item.task("- plain bullet"), nil)

	local kr = require("zortex.services.okr.objective").parse_key_result("- KR2: [x] Ship it [P/#1 Programming]")
	T.eq({ kr.id, kr.completed, kr.links }, { "KR2", true, { "P/#1 Programming" } })

	local CalendarEntry = require("zortex.services.calendar_entry")
	local ev = CalendarEntry.from_text("16:00 - 17:00 Wrench", "2026-10-09")
	T.eq({ ev.type, ev.text, ev:get_time_string() }, { "event", "Wrench", "16:00" })
	T.eq(CalendarEntry.from_text("- [x] Order parts", "2026-10-06").type, "task")
	T.eq(CalendarEntry.from_text("just a note line", "2026-10-06"), nil)
end)

T.test("conformance: fixtures parse to tests/fixtures/ast", function()
	local gen = dofile(T.root .. "/tests/gen_ast.lua")
	local sources = gen.sources()
	T.ok(#sources >= 6, "fixtures found")
	for _, src in ipairs(sources) do
		local expected = vim.json.decode(table.concat(vim.fn.readfile(gen.ast_path(src.name)), "\n"))
		local actual = vim.json.decode(vim.json.encode(gen.parse(src.path)))
		T.eq(actual, expected, src.name .. " (regenerate with: nvim --headless -u NONE -l tests/gen_ast.lua)")
	end
end)

T.test("bold headings show their text and colon, not the stars", function()
	local hl = require("zortex.features.highlights")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	local lines = { "**Heading:**", "**Next steps:**  " }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	hl.highlight_buffer(buf)
	local ns = vim.api.nvim_create_namespace("zortex_highlights")
	for row, line in ipairs(lines) do
		local hidden, painted = {}, nil
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
			if m[4].conceal == "" then
				for col = m[3], m[4].end_col - 1 do
					hidden[col] = true
				end
			elseif m[4].hl_group == "ZortexBoldHeading" then
				painted = line:sub(m[3] + 1, m[4].end_col)
			end
		end
		local shown = {}
		for col = 0, #line - 1 do
			if not hidden[col] then
				shown[#shown + 1] = line:sub(col + 1, col + 1)
			end
		end
		local title = line:match("^%*%*(.-)%*%*")
		T.eq(vim.trim(table.concat(shown)), title, line)
		T.eq(painted, title, line)
	end
	vim.cmd("bwipeout!")
end)

T.test("tags are painted on any line; the @ of @[tags] is dimmed", function()
	local hl = require("zortex.features.highlights")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	local lines = { "Some prose about borrowing @rust @ai-model", "> a quote @rl", "- AI @[rl, ai-model]" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	hl.highlight_buffer(buf)
	local ns = vim.api.nvim_create_namespace("zortex_highlights")
	local painted = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local g = m[4].hl_group
		if g == "ZortexAttribute" or g == "ZortexTagSearchAt" then
			painted[#painted + 1] = g .. " " .. lines[m[2] + 1]:sub(m[3] + 1, m[4].end_col)
		end
	end
	T.eq(painted, {
		"ZortexAttribute @rust",
		"ZortexAttribute @ai-model",
		"ZortexAttribute @rl",
		"ZortexTagSearchAt @",
	})
	vim.cmd("bwipeout!")
end)

T.test("link icons leave with their lines, not piled on the next one", function()
	local hl = require("zortex.features.highlights")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "top", "See [A]", "- [Bee] and [C]", "See [D](x.md)", "end" })
	hl.highlight_buffer(buf)
	local ns = vim.api.nvim_create_namespace("zortex_highlights")
	local function icons()
		local rows = {}
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
			if m[4].virt_text and m[4].virt_text[1][1] == "🔗" and not m[4].invalid then
				rows[#rows + 1] = m[2]
			end
		end
		return rows
	end
	T.eq(icons(), { 1, 2, 2, 3 })
	-- the lines leave without a repaint (as when they move to another note)
	vim.api.nvim_buf_set_lines(buf, 1, 4, false, {})
	T.eq(icons(), {})
	vim.cmd("bwipeout!")
end)

T.test("a heading's @attributes look like attributes, not like the heading", function()
	local hl = require("zortex.features.highlights")
	hl.setup_highlights()
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	local line = "## 1.4 - zortex @size(lg) @a(4.1) @p1"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	hl.highlight_buffer(buf)
	local ns = vim.api.nvim_create_namespace("zortex_highlights")
	local painted, line_group = {}, nil
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local g = m[4].hl_group
		if g == "ZortexHeading2" or g == "ZortexAttribute" then
			painted[#painted + 1] = g .. " " .. vim.trim(line:sub(m[3] + 1, m[4].end_col))
		end
		line_group = m[4].line_hl_group or line_group
	end
	table.sort(painted)
	T.eq(painted, {
		"ZortexAttribute @a(4.1)",
		"ZortexAttribute @p1",
		"ZortexAttribute @size(lg)",
		"ZortexHeading2 ## 1.4 - zortex",
	})
	-- the line's band is only the heading's background: nothing bold under the attributes
	T.eq(line_group, "ZortexHeading2Line")
	local band = vim.api.nvim_get_hl(0, { name = "ZortexHeading2Line" })
	T.ok(not band.bold and not band.fg, vim.inspect(band))
	vim.cmd("bwipeout!")
end)

T.test("highlights paint from the syntax", function()
	local hl = require("zortex.features.highlights")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample())
	hl.highlight_buffer(buf)
	local ns = vim.api.nvim_create_namespace("zortex_highlights")
	local groups = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		if m[4].hl_group then
			groups[m[4].hl_group] = true
		end
	end
	for _, g in ipairs({
		"ZortexArticle",
		"ZortexHeading1",
		"ZortexBoldHeading",
		"ZortexLabel",
		"ZortexLabelList",
		"ZortexObjective",
		"ZortexKeyResult",
		"ZortexKeyResultDone",
		"ZortexTaskText",
		"ZortexTaskDone",
		"ZortexLinkNote",
		"ZortexLinkHeading",
		"ZortexAttribute",
		"ZortexCodeBlock",
		"ZortexMathBlock",
		"ZortexTableSeparator",
		"ZortexBlockQuote",
		"ZortexTime",
		"ZortexMarkdownLink",
		"ZortexFootnote",
		"ZortexURL",
		"ZortexBold",
		"ZortexItalic",
		"ZortexCodeInline",
		"ZortexMathInline",
		"ZortexLabelText",
		"ZortexPercent",
	}) do
		T.ok(groups[g], "painted " .. g)
	end
	vim.cmd("bwipeout!")
end)

T.test("a link is coloured by what its last component names", function()
	local kind = require("zortex.core.link").kind
	T.eq(kind("Projects"), "note")
	T.eq(kind("[@Cars]"), "note")
	T.eq(kind("P/#1.4 - zortex"), "heading")
	T.eq(kind("A/#1.2/:Fitness"), "label")
	T.eq(kind("Note/*Next steps"), "bold")
	T.eq(kind("O/#Current/-KR1"), "item")
	T.eq(kind("./-Item"), "item")
	T.eq(kind("/#Local"), "heading")
	T.eq(kind("Note/%sparkplug"), nil)
	T.eq(kind("R/#Rust/>The Rust Book"), nil)
end)

T.test("folds follow sections and indentation", function()
	local folding = require("zortex.features.folding")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"@@Note",
		"# One",
		"- item",
		"  - child",
		"```",
		"# code, not a heading",
		"```",
		"## Two",
		"Label:",
		"  text",
	})
	folding.update_folds(buf)
	local f = vim.b[buf].zortex_folds
	T.eq({ f[1], f[2], f[3], f[4], f[6], f[8], f[9], f[10] }, { ">0", ">1", ">2", "2", "1", ">2", ">3", "4" })
	vim.cmd("bwipeout!")
end)

T.test("@fold sections start closed; an opened one stays open", function()
	local folding = require("zortex.features.folding")
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"@@Note",
		"# Open",
		"text",
		"# Archive @fold",
		"old",
		"- list @fold",
		"  - child",
		"Some @fold text",
	})
	folding.update_folds(buf)
	T.eq(vim.b[buf].zortex_fold_closed, { 4, 6 })
	vim.wo.foldmethod = "expr"
	vim.wo.foldexpr = "v:lua._zortex_foldexpr(v:lnum)"
	vim.wo.foldlevel = 99
	folding.close_marked(0, buf)
	T.eq({ vim.fn.foldclosed(2), vim.fn.foldclosed(4), vim.fn.foldclosed(8) }, { -1, 4, 4 })
	vim.cmd("4foldopen")
	T.eq(vim.fn.foldclosed(7), 6) -- the nested @fold item is closed too
	vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "older" })
	folding.update_folds(buf)
	T.eq(vim.fn.foldclosed(4), -1)
	vim.cmd("bwipeout!")
end)

T.test("core/syntax runs without Neovim (no vim.* in the grammar)", function()
	-- Load syntax.lua and constants.lua in an environment that has only the
	-- Lua standard library, and parse the sample.
	local function sandbox()
		local env = {}
		for _, k in ipairs({
			"string",
			"table",
			"math",
			"ipairs",
			"pairs",
			"next",
			"select",
			"tostring",
			"tonumber",
			"type",
			"setmetatable",
			"getmetatable",
			"error",
			"pcall",
		}) do
			env[k] = _G[k]
		end
		local loaded = {}
		env.require = function(name)
			if not loaded[name] then
				local path = T.root .. "/lua/" .. name:gsub("%.", "/") .. ".lua"
				local chunk = assert(loadfile(path))
				setfenv(chunk, env)
				loaded[name] = chunk()
			end
			return loaded[name]
		end
		return env
	end
	local syntax = sandbox().require("zortex.core.syntax")
	local ast = syntax.parse(sample(), { inline = true })
	local expected = require("zortex.core.syntax").parse(sample(), { inline = true })
	T.eq(ast, expected)
end)

T.test("attributes start a word: links and emails keep their @", function()
	local CalendarEntry = require("zortex.services.calendar_entry")
	local ev = CalendarEntry.from_text("16:00 - 17:00 Wrench on [@P/#Subaru] @p1", "2026-10-09")
	T.eq({ ev.text, ev.attributes.p, ev.attributes.tags }, { "Wrench on [@P/#Subaru]", "1", nil })
	local task = require("zortex.core.item").task("- [ ] Mail me@example.com @home @AI-model @home @p1")
	T.eq({ task.text, task.attributes.tags, task.attributes.p }, { "Mail me@example.com", { "home", "ai-model" }, "1" })
	local timed = CalendarEntry.from_text("- 09:30 Standup @dur(15m)", "2026-10-12")
	T.eq({ timed:get_end_time().hour, timed:get_end_time().min }, { 9, 45 })
end)

T.test("bold headings are **Text:** only", function()
	local k = function(line)
		return syntax.classify(line)
	end
	local d = k("**Fitness:**")
	T.eq({ d.kind, d.text, d.content_col, d.content_end }, { "bold_heading", "Fitness", 2, 9 })
	T.eq(k("**Spaced:**   ").kind, "bold_heading")
	T.eq(k("**Ideas @a(4.1):**").text, "Ideas")
	-- bold text, with or without a colon after it, is not a bold heading
	T.ok(k("**Fitness**").kind ~= "bold_heading")
	T.ok(k("**Fitness**:").kind ~= "bold_heading")
	T.ok(k("**:**").kind ~= "bold_heading")
	T.ok(k("**Fitness:** more").kind ~= "bold_heading")
end)

T.test("[*Text] reaches a bold heading", function()
	local Document = require("zortex.core.document")
	local link = require("zortex.core.link")
	local doc = Document.from_lines({ "@@Gym", "", "**Warmup:**", "- jog", "", "Some **plain** bold" }, "/tmp/gym.zortex")
	local r = link.resolve("/*Warmup", { doc = doc })
	T.eq(r[1] and r[1].lnum, 3)
	T.eq(link.resolve("/*plain", { doc = doc })[1].lnum, 6)
end)

T.test("labels: three words at most, or *a longer label:*", function()
	local syntax = require("zortex.core.syntax")
	local kind = function(l)
		return syntax.classify(l).kind
	end
	T.eq(kind("First thing tomorrow:"), "label")
	T.eq(kind("Archive @fold @p1:"), "label")
	T.eq(kind("Things that grew too well:"), "text")
	T.eq(kind("*Things that grew too well:*"), "label")
	T.eq(syntax.classify("*Things that grew too well:*").text, "Things that grew too well")
	T.eq(kind("- Four words in item:"), "item")
	T.eq(kind("**Bold**:"), "text", "bold text before the colon")
	T.eq(kind("**Bold:**"), "bold_heading")
end)
