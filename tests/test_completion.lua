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
	local resolver = require("zortex.core.link")
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

T.test("a path matching several sections offers the children of each", function()
	vim.cmd("edit " .. vim.fn.fnameescape(T.fixture("calendar.zortex")))
	local C = require("zortex.features.completion")
	local items = C.get_completions("[P/#1/", 6, {})
	local labels = {}
	for _, i in ipairs(items) do
		labels[i.label] = true
	end
	T.ok(labels["#1.4 - zortex"], "child of 1 Programming")
	T.ok(labels["#Habits"], "child of 1 Personal, its sibling")
end)

T.test("setup twice registers the cmp source once", function()
	local sources, next_id = {}, 0
	package.loaded.cmp = {
		register_source = function(name, src)
			next_id = next_id + 1
			sources[next_id] = name
			return next_id
		end,
		unregister_source = function(id)
			sources[id] = nil
		end,
	}
	local C = require("zortex.features.completion")
	C._cmp_id = nil
	C.register_cmp()
	C.register_cmp()
	C.register_cmp()
	T.eq(vim.tbl_count(sources), 1)
	package.loaded.cmp = nil
	C._cmp_id = nil
end)

T.test("[P/ also offers headings of @P notes the Projects note doesn't shadow", function()
	vim.cmd("edit " .. vim.fn.fnameescape(T.fixture("calendar.zortex")))
	local items = C.get_completions("[P/#Sub", 7, {})
	local found
	for _, i in ipairs(items) do
		if i.label == "#Subaru outback" then
			found = i
		end
	end
	T.ok(found, "standalone project's heading offered")
	local r = require("zortex.core.link").resolve_first("[P/#Subaru outback]")
	T.ok(r and r.file:match("flipping%.zortex$"), "and it resolves there")
	-- a heading the Projects note also has stays the Projects note's
	for _, i in ipairs(items) do
		local res = require("zortex.core.link").resolve_first("[P/" .. i.label .. "]")
		T.ok(res, "resolves: " .. i.label)
	end
end)

T.test("@a( and @area( complete areas as a tree, inserting values that resolve", function()
	local ctx = C.area_context("## Cars @a(", 11)
	T.eq(ctx and ctx.typing, "")
	T.eq(C.area_context("- [ ] x @area(4.1, Fi", 21).typing, "Fi")
	T.eq(C.area_context("mail me@a(", 10), nil)
	T.eq(C.area_context("@a(4.1) done", 12), nil)
	local items = C.get_completions("## Cars @a(", 11, {})
	T.ok(#items >= 6, "areas offered")
	local by_value = {}
	for _, i in ipairs(items) do
		by_value[i.area_value] = i
		local def = require("zortex.utils.attributes").attribute_parsers.area(i.area_value)[1].definition
		local area = require("zortex.services.areas").resolve(def)
		T.ok(area, "resolves: " .. i.area_value)
	end
	T.ok(by_value["4.1"] and by_value["4.1"].label:match("^  4%.1 Education"), "short value, indented label")
	T.ok(by_value["1.2/Fitness"], "labels go through their heading")
end)

-- nvim-cmp filters items against the text from the source's keyword start to
-- the cursor (keyword pattern + "\m$"). It must start where the value being
-- typed starts: before this, "- [ ] x @a(" was all "typed" text from the
-- last "]" and every area was filtered away.
T.test("cmp keyword pattern starts at the value being typed", function()
	local completion = require("zortex.features.completion")
	local pat = completion.new():get_keyword_pattern()
	local re = vim.regex([[\%(]] .. pat .. [[\)\m$]])
	local function typed(line)
		local s = re:match_str(line)
		return s and line:sub(s + 1) or nil
	end
	T.eq(typed("- [ ] Tune bike @a("), "")
	T.eq(typed("@area("), "")
	T.eq(typed("- [ ] x @a(4."), "4.")
	T.eq(typed("- [ ] x @a(4.1, 1.2/Fit"), "Fit")
	T.eq(typed("See [P/#1.4 - zor"), "#1.4 - zor")
	T.eq(typed("See [Flipping"), "Flipping")
	-- and the area context agrees on where the value starts
	for _, line in ipairs({ "- [ ] x @a(4.", "@area(", "- [ ] x @a(4.1, 1" }) do
		local ctx = completion.area_context(line, #line)
		T.eq(ctx.typing_col, #line - #typed(line), line)
	end
end)

T.test("area items keep the Areas note's order in cmp", function()
	local completion = require("zortex.features.completion")
	local items = completion._area_items()
	local function entry(item)
		return { completion_item = item }
	end
	for i = 2, #items do
		T.eq(completion.order_comparator(entry(items[i - 1]), entry(items[i])), true, items[i].label)
		T.eq(completion.order_comparator(entry(items[i]), entry(items[i - 1])), false)
	end
	-- anything that isn't an area item is left to cmp's own comparators
	T.eq(completion.order_comparator(entry({ label = "x" }), entry(items[1])), nil)
end)

T.test("'>' offers the links in range", function()
	T.eq(labels("[R/#Rust/#Embedded/>"), { ">The Embedded Rust Book", ">Pinout" })
	local l = labels("[R/#AI/>")
	T.ok(has(l, ">Sutton  Barto") or has(l, ">Sutton"), vim.inspect(l))
	T.ok(has(l, ">lecture notes") and has(l, ">Spinning Up"), vim.inspect(l))
	for _, label in ipairs(labels("[R/#Rust/>")) do
		T.ok(#require("zortex.core.link").resolve("[R/#Rust/" .. label .. "]") > 0, label)
	end
end)

T.test("tags: after a bare @ and inside @[...], most used first", function()
	T.eq(C.tag_context("prose @ru", 9), { typing = "@ru", typing_col = 6, tag = "bare" })
	T.eq(C.tag_context("see @[R/rust as", 15), { typing = "as", typing_col = 13, tag = "search" })
	T.eq(C.tag_context("mail me@ex", 10), nil) -- not a word start
	T.eq(C.tag_context("@[rust] done", 12), nil) -- a closed search

	local items = C.get_completions("- [x](https://x.org) @", #"- [x](https://x.org) @", { doc = doc })
	local by = {}
	for _, i in ipairs(items) do
		by[i.label] = i
	end
	T.ok(by["@rust"] and by["@rl"] and by["@ai-model"], vim.inspect(vim.tbl_keys(by)))
	T.ok(by["@rust"].detail:match("^%d+ lines$"), by["@rust"].detail)
	T.ok(not by["@p1"] and not by["@sm"], "shortcut attributes aren't tags")
	T.eq(items[1].label, "@rust") -- the most used tag in the fixtures

	-- inside a search: plain words, replacing only the word being typed
	local line = "@[R/rust a"
	local lsp = C.lsp_items(line, 0, 0)
	local async
	for _, i in ipairs(lsp) do
		if i.label == "async" then
			async = i
		end
	end
	T.ok(async, "async offered")
	T.eq(async.textEdit.range.start.character, #"@[R/rust ")
	T.eq(async.filterText, "rust async") -- what nvim-cmp compares with "rust a"
end)

-- "[./" continues the link of the line it's nested under
local function rel_labels(lines, typed)
	lines = vim.list_extend(vim.deepcopy(lines), { typed })
	local d = Document.from_lines(lines, "/tmp/plan.zortex")
	local items = C.get_completions(typed, #typed, { doc = d, lnum = #lines })
	return vim.tbl_map(function(i)
		return i.label
	end, items)
end

T.test("'[./' completes from the parent line's link: items, sections, links", function()
	local cal = { "@@Calendar", "", "2026-10-15:", "16:00 [P/#1 Programming/#1.4 - zortex]" }
	-- "-" lists the section's items, its own first
	local items = rel_labels(cal, "    - [ ] [./-")
	T.eq(items[1], "-Add research-ready references")
	T.ok(has(items, "-Improve website") and has(items, "-Calendar doesn"), vim.inspect(items))
	T.ok(not has(items, "#1.4.1 - zortex search"), "only items after -")
	T.ok(has(items, "-Fix project search"), "items of sub-sections come after")
	-- "#", ":" and "*" narrow to that kind of section
	T.eq(rel_labels(cal, "    - [./#"), { "#1.4.1 - zortex search" })
	T.eq(rel_labels(cal, "    - [./:"), { ":Notes" })
	-- right after "./": sections and items
	local all = rel_labels(cal, "    - [./")
	T.ok(has(all, "#1.4.1 - zortex search") and has(all, "-Improve website"), vim.inspect(all))
	-- a relative parent continues its own parent
	local nested = vim.list_extend(vim.deepcopy(cal), { "    - [./#1.4.1 - zortex search]" })
	T.eq(rel_labels(nested, "        - [./-"), { "-Fix project search" })
	-- no parent link, or a file path: nothing
	T.eq(rel_labels({ "@@X", "" }, "- [./-"), {})
	T.eq(rel_labels(cal, "    - [./sc"), {})
end)

T.test("'-' after a section lists its items anywhere in a link", function()
	local l = labels("[P/#1 Programming/#1.4 - zortex/-Imp")
	T.ok(has(l, "-Improve website"), vim.inspect(l))
	T.ok(not has(l, "#1.4.1 - zortex search"), vim.inspect(l))
end)
