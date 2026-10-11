local T = require("helpers")
local C = require("zortex.features.completion")
local Document = require("zortex.core.document")

local doc = Document.get(T.fixture("projects.zortex"))

local function labels(line)
	local items = C.get_completions(line, #line, { doc = doc })
	return vim.tbl_map(function(i)
		return i.label
	end, items)
end

local function has(list, value)
	return vim.tbl_contains(list, value)
end

T.test("context: completed parts, typing, insert column", function()
	local ctx = C.link_context("see [P/#1 Programming/#1.4", #"see [P/#1 Programming/#1.4")
	T.eq(ctx.parts, { "P", "#1 Programming" })
	T.eq(ctx.typing, "#1.4")
	T.eq(ctx.typing_col, #"see [P/#1 Programming/")
	T.eq(C.link_context("a [done] b", 10), nil) -- closed link
	T.eq(C.link_context("no link", 7), nil)
	T.eq(C.link_context("[^foot", 6), nil)
end)

T.test("'[' offers article names and aliases", function()
	local l = labels("[")
	for _, name in ipairs({ "Projects", "P", "Flipping", "Car maintenance", "Areas", "A" }) do
		T.ok(has(l, name), name)
	end
	T.ok(not has(l, "Projects") or not vim.tbl_contains(l, "archive"), "no archive")
end)

T.test("'[@' offers tags", function()
	local l = labels("[@")
	T.ok(has(l, "@P") and has(l, "@Cars") and has(l, "@Me"), vim.inspect(l))
	T.ok(not has(l, "@Archive"), "archived notes excluded")
end)

T.test("'[P/' offers the article's sections (children first) and tagged notes", function()
	local l = labels("[P/")
	T.eq(l[1], "Flipping") -- articles sort first
	T.ok(has(l, "Garden"), "tagged note")
	local i1, i2 = nil, nil
	for i, x in ipairs(l) do
		if x == "#1 Programming" then
			i1 = i
		elseif x == "#1.4 - zortex" then
			i2 = i
		end
	end
	T.ok(i1 and i2 and i1 < i2, "children before grandchildren")
end)

T.test("sections inside a resolved section, narrowed by '#'", function()
	T.eq(labels("[P/#1 Programming/#"), { "#1.4 - esp32", "#1.4 - zortex", "#1.4.1 - zortex search" })
	T.eq(labels("[A/#1.2 Vitality/:"), { ":Fitness" })
end)

T.test("'[@P/' offers note names and their sections", function()
	local l = labels("[@P/")
	T.ok(has(l, "Flipping") and has(l, "Garden") and has(l, "#Subaru outback"), vim.inspect(l))
end)

T.test("every suggestion resolves", function()
	local resolver = require("zortex.utils.link_resolver")
	for _, prefix in ipairs({ "[P/", "[P/#1 Programming/", "[A/", "[@P/" }) do
		for _, label in ipairs(labels(prefix)) do
			local link = prefix .. label .. "]"
			T.ok(resolver.resolve_first(link), "unresolved suggestion " .. link)
		end
	end
end)

T.test("local links complete sections of the current note", function()
	local l = labels("[/")
	T.ok(has(l, "#1 Programming") and has(l, ":Notes"), vim.inspect(l))
end)
