local T = require("helpers")
local links = require("zortex.core.link")

local function target(link)
	local r, err = links.resolve_first(link)
	T.ok(r, err)
	return vim.fn.fnamemodify(r.file, ":t") .. ":" .. r.lnum
end

T.test("alias + heading prefix, skipping levels, case-insensitive", function()
	T.eq(target("[P/#1.4 - zortex]"), "projects.zortex:14")
	T.eq(target("[P/#1.4 - Zortex]"), "projects.zortex:14")
	T.eq(target("[Projects/#1 Programming/#1.4 - zortex]"), "projects.zortex:14")
end)

T.test("first match is canonical (parent before children sharing a prefix)", function()
	local results = links.resolve("[P/#1.4]")
	T.eq(#results, 3)
	T.eq(results[1].lnum, 11) -- 1.4 - esp32 comes first in the file
	T.eq(target("[P/#1]"), "projects.zortex:7")
end)

T.test("archived notes are skipped unless asked for", function()
	for _, r in ipairs(links.resolve("[P/#1.4 - zortex]")) do
		T.ok(not r.file:find("archive"), "archive leaked into results")
	end
	T.eq(target("[@Archive/#1.4 - zortex]"), "archive.projects.zortex:6")
end)

T.test("[@P/...] reaches standalone project notes", function()
	T.eq(target("[@P/#Subaru outback]"), "flipping.zortex:11")
	T.eq(target("[@P/Flipping/#Subaru]"), "flipping.zortex:11")
	local tagged = links.resolve("[@P]")
	T.eq(#tagged, 2)
end)

T.test("article link resolves to the article line", function()
	T.eq(target("[Car maintenance]"), "flipping.zortex:1")
end)

T.test("nested path narrows to the section", function()
	T.eq(target("[P/#1 Personal/#Habits]"), "projects.zortex:30")
	local r = links.resolve("[P/#1 Personal/#1.4]")
	T.eq(#r, 0)
end)

T.test("link_for_node round-trips", function()
	local Document = require("zortex.core.document")
	local doc = Document.from_file(require("helpers").fixture("projects.zortex"))
	doc.tree:walk(function(n)
		if n.type == "heading" then
			local link = links.link_for_node(doc, n)
			local node = links.resolve_node(link)
			T.eq(node and node.start_line, n.start_line, link)
		end
	end)
end)

T.test("build_result_link uses clean section paths", function()
	local r = links.resolve_first("[P/#1.4 - zortex/%website]")
	T.eq(links.build_result_link(r), "[Projects/#1 Programming/#1.4 - zortex/%Improve website]")
end)

T.test("article component: alias files first, then tagged files", function()
	local results = links.resolve("[P]")
	T.eq(vim.tbl_map(function(r)
		return vim.fn.fnamemodify(r.file, ":t")
	end, results), { "projects.zortex", "flipping.zortex", "garden.zortex" })
	T.eq(target("[P/Flipping/#Subaru]"), "flipping.zortex:11")
end)

T.test("task checkboxes are not links", function()
	local link = require("zortex.core.link")
	T.eq(#link.on_line("- [ ] Task"), 0)
	T.eq(#link.on_line("- [x] Done [P/#1.4]"), 1)
	T.eq(link.on_line("- KR1: [ ] text [P/#Habits]")[1].definition, "P/#Habits")
end)

T.test("> components match links by their text or their line's text", function()
	local r = links.resolve("[R/#Rust/>Garden notes]")
	T.eq(vim.tbl_map(function(x)
		return x.target.definition
	end, r), { "Garden/-Plant", "Flipping/#Subaru" })
	T.eq(links.resolve_first("[R/>the rust]").target.url, "https://doc.rust-lang.org/book")
	T.eq(links.build_result_link(links.resolve_first("[R/>The Rust Book]")), "[Resources/#Rust/>The Rust Book]")
	T.eq(links.build_result_link(links.resolve_first("[R/#Rust/>Async]")), "[Resources/#Rust/>Async book]")
	T.eq(#links.resolve("[R/#Embedded/>]"), 2)
	local _, err = links.resolve("[R/>Spinning/#AI]")
	T.eq(err, "Nothing can come after >Spinning")
	T.eq(links.parse_component(">Sutton & Barto").type, "follow")
end)

T.test("following a > link opens the link it matched, or picks one", function()
	local follow = require("zortex.features.links")
	local select = vim.ui.select
	local shown
	vim.ui.select = function(items, opts, choose)
		shown = vim.tbl_map(opts.format_item, items)
		choose(items[2])
	end
	local ok, err = pcall(function()
		follow.open_info({ type = "link", definition = "R/#Rust/>Garden notes" })
		T.eq(shown, {
			"Garden notes — [Garden/-Plant] (Resources › Rust)",
			"Garden notes — [Flipping/#Subaru] (Resources › Rust)",
		})
		T.eq(vim.fn.expand("%:t") .. ":" .. vim.fn.line("."), "flipping.zortex:11")
		shown = nil
		vim.cmd("enew")
		follow.open_info({ type = "link", definition = "R/#Rust/>Flipping" })
		T.eq(shown, nil) -- one match: no picker
		T.eq(vim.fn.expand("%:t") .. ":" .. vim.fn.line("."), "flipping.zortex:11")
	end)
	vim.ui.select = select
	assert(ok, err)
end)

T.test("a link written as a relative path opens that file", function()
	local from = T.fixture("z/resources.zortex")
	T.eq(links.relative_path("./garden.zortex#Plant", from), T.fixture("z/garden.zortex"))
	T.eq(links.relative_path("../okr.zortex", from), T.fixture("okr.zortex"))
	T.eq(links.relative_path("Garden/-Plant", from), nil)
	require("zortex.features.links").open_info({ type = "link", definition = "../okr.zortex" }, { file = from })
	T.eq(vim.fn.expand("%:t"), "okr.zortex")
	vim.cmd("enew")
end)

T.test("the > picker shows each link's title, short target and section", function()
	local doc = require("zortex.core.document").from_lines({
		"@@Books",
		"# Electronics",
		"- The Art of Electronics. Horowitz: ./z/books/the-art-of-electronics.horowitz.pdf @ee",
		"- [Practical Electronics](https://www.example.com/pe) @ee",
		"- https://example.org/notes - lecture notes",
	}, "/tmp/books.zortex")
	local entries = vim.tbl_map(require("zortex.features.links")._follow_entry, links.resolve("[/>]", { doc = doc }))
	T.eq(vim.tbl_map(function(e)
		return { e.title, e.target, e.where }
	end, entries), {
		{ "The Art of Electronics. Horowitz", "the-art-of-electronics.horowitz.pdf", "Books › Electronics" },
		{ "Practical Electronics", "example.com/pe", "Books › Electronics" },
		{ "lecture notes", "example.org/notes", "Books › Electronics" },
	})
end)

T.test("@[scope/tags] finds tagged lines, with tags inherited from headings", function()
	local function lines(link, opts)
		local out = {}
		for _, r in ipairs(links.resolve(link, opts)) do
			out[#out + 1] = r.lnum
		end
		return out
	end
	T.eq(lines("@[R/rust]"), { 9, 12, 13, 16 })
	T.eq(lines("@[R/embedded rust]"), { 16 }) -- @embedded on the heading, @rust on the line
	T.eq(lines("@[@Library/rl, ai-model]"), { 20, 21 })
	T.eq(lines("@[*/@rl @ai-model]"), { 21 })
	local doc = require("zortex.core.document").get(T.fixture("z/resources.zortex"))
	T.eq(lines("@[rl]", { doc = doc }), { 20, 21 })
	T.eq(links.parse_tag_search("R/#Rust/a b, c").groups, { { "a", "b" }, { "c" } })
	T.eq(links.parse_tag_search("c++, r&d").groups, { { "c++" }, { "r&d" } }) -- no other operators
	local _, err = links.resolve("@[Nope/rl]")
	T.eq(err, "No article found: Nope")
end)

T.test("following @[...] lists the tagged lines, not the search itself", function()
	local follow = require("zortex.features.links")
	vim.cmd("edit " .. T.fixture("z/resources.zortex"))
	vim.api.nvim_win_set_cursor(0, { 6, 6 }) -- - AI @[rl ai-model]
	follow.open_info(require("zortex.core.link").at(vim.api.nvim_get_current_line(), 6))
	T.eq(vim.fn.expand("%:t") .. ":" .. vim.fn.line("."), "resources.zortex:21")
	vim.cmd("enew")
end)

T.test("- matches a list item by its markdown link's text", function()
	T.eq(target("[R/#Rust/-The Rust Book]"), "resources.zortex:9")
	T.eq(links.item_component("- [The Rust Book](https://doc.rust-lang.org/book) @rust"), "-The Rust Book")
	T.eq(links.link_text("- [a](x) and **[b](y)** c", 2), "a and **b** c")
end)

T.test("conformance: resolve and search fixtures are up to date", function()
	local Config = require("zortex.config")
	local saved = Config.notes_dir
	local gen = dofile(T.root .. "/tests/gen_links.lua")
	local function read(path)
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end
	local hint = " (regenerate with: nvim --headless -u NONE -l tests/gen_links.lua)"
	local ok, err = pcall(function()
		gen.use_fixture_copy() -- pristine notes, whatever earlier tests wrote
		T.eq(vim.json.decode(vim.json.encode(gen.resolve_cases())), read(gen.RESOLVE), "resolve.json" .. hint)
		T.eq(vim.json.decode(vim.json.encode(gen.search_cases())), read(gen.SEARCH), "search.json" .. hint)
	end)
	Config.notes_dir = saved
	require("zortex.core.notes").invalidate()
	require("zortex.core.document").invalidate()
	assert(ok, err)
end)

T.test("heading and tag searches stay inside the range", function()
	local lines = { "# Beta", "beta", "# Alpha", "## beta two", "@Beta", "# BETA" }
	local function lnums(component, s, e)
		return vim.tbl_map(function(m)
			return m.lnum
		end, links.search_lines(lines, component, s, e))
	end
	T.eq(lnums({ type = "heading", text = "beta" }), { 1, 4, 6 })
	T.eq(lnums({ type = "heading", text = "beta" }, 2, 5), { 4 })
	T.eq(lnums({ type = "heading", text = "beta" }, 1, 1), { 1 })
	T.eq(lnums({ type = "tag", text = "beta" }, 3), { 5 })
	T.eq(lnums({ type = "query", text = "beta" }, 2, 4), { 2, 4 })
end)
