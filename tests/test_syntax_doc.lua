-- doc/Syntax.md stays true: every example in its checked tables is a line of
-- tests/fixtures/syntax, and the parser gives it the kind or span listed.
local T = require("helpers")
local syntax = require("zortex.core.syntax")

local function read(path)
	return vim.fn.readfile(path)
end

-- markdown table cell -> the code it shows: `x` or `` x ``, with \| unescaped
local function code_cell(cell)
	cell = vim.trim(cell)
	local inner = cell:match("^`` (.*) ``$") or cell:match("^`(.*)`$")
	return inner and (inner:gsub("\\|", "|")) or nil
end

local function split_row(line)
	local cells, cur, i = {}, "", 2 -- skip the leading "|"
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and line:sub(i + 1, i + 1) == "|" then
			cur = cur .. "\\|"
			i = i + 2
		elseif c == "|" then
			cells[#cells + 1] = cur
			cur = ""
			i = i + 1
		else
			cur = cur .. c
			i = i + 1
		end
	end
	return cells
end

-- rows of the table after "<!-- check: name -->"
local function checked_rows(doc, name)
	local rows, on, seen_header = {}, false, false
	for _, line in ipairs(doc) do
		if line == "<!-- check: " .. name .. " -->" then
			on = true
		elseif on then
			if not line:match("^|") then
				if seen_header then
					break
				end
			elseif line:match("^|%-") then
				seen_header = true
			elseif seen_header then
				local cells = split_row(line)
				rows[#rows + 1] = { example = code_cell(cells[1]), expect = code_cell(cells[2]), raw = line }
			end
		end
	end
	return rows
end

local doc = read(T.root .. "/doc/Syntax.md")
-- the hand-written fixtures (random.zortex is generated noise)
local fixtures = {}
for _, name in ipairs({ "sample.zortex", "edge.zortex" }) do
	local lines = read(T.root .. "/tests/fixtures/syntax/" .. name)
	fixtures[#fixtures + 1] = { name = name, lines = lines, ast = syntax.parse(lines, { inline = true }) }
end

T.test("line kinds in doc/Syntax.md match the parser", function()
	local rows = checked_rows(doc, "lines")
	T.ok(#rows >= 30, "found the lines table (" .. #rows .. " rows)")
	for _, row in ipairs(rows) do
		T.ok(row.example and row.expect, "unreadable row: " .. row.raw)
		-- its first occurrence (sample before edge)
		local found = false
		for _, f in ipairs(fixtures) do
			for i, l in ipairs(f.lines) do
				if not found and l == row.example then
					found = true
					T.eq(f.ast.lines[i].kind, row.expect, string.format("%s:%d %q", f.name, i, l))
				end
			end
		end
		T.ok(found, "not a line of tests/fixtures/syntax: " .. row.example)
	end
end)

T.test("inline spans in doc/Syntax.md match the parser", function()
	local rows = checked_rows(doc, "inline")
	T.ok(#rows >= 10, "found the inline table (" .. #rows .. " rows)")
	for _, row in ipairs(rows) do
		local found = false
		for _, f in ipairs(fixtures) do
			for i, l in ipairs(f.lines) do
				syntax.walk_spans(f.ast.lines[i].inline or {}, function(sp)
					if sp.type == row.expect and l:sub(sp.s + 1, sp.e) == row.example then
						found = true
					end
				end)
			end
		end
		T.ok(found, string.format("no %s span %q in tests/fixtures/syntax", row.expect, row.example))
	end
end)
