local T = require("helpers")
local search = require("zortex.ui.telescope.search")
local fs = require("zortex.utils.filesystem")

local function index()
	return search.build_index(fs.find_all_notes())
end

local function sections(results)
	return vim.tbl_filter(function(r)
		return r.result_type == "section"
	end, results)
end

local function crumbs(results)
	return vim.tbl_map(function(r)
		return r.breadcrumb or r.line
	end, results)
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

T.test("setup overlays user options on the defaults", function()
	local cfg = search.setup({ max_results = 7, history = { enabled = false } })
	T.eq(cfg.max_results, 7)
	T.eq(cfg.default_mode, "section") -- untouched default
	T.eq(cfg.history.enabled, false)
	T.eq(cfg.history.max_entries, 50) -- sibling default kept
	T.ok(cfg.token_filters[1], "token filters present")
	T.eq(require("zortex.config").defaults.ui.search.max_results, 500) -- defaults not mutated
	search.setup()
end)

-- ---------------------------------------------------------------------------
-- Tokens and ordered path matching
-- ---------------------------------------------------------------------------

T.test("tokenizer: typed prefixes, '_' and '\\ ' are spaces", function()
	local toks = search._tokenize("@@Proj #1.4_zortex :Fit *bold plain a\\ b ##deep @@")
	T.eq(toks, {
		{ type = "article", text = "proj" },
		{ type = "heading", text = "1.4 zortex" },
		{ type = "label", text = "fit" },
		{ type = "bold_heading", text = "bold" },
		{ type = "general", text = "plain" },
		{ type = "general", text = "a b" },
		{ type = "heading", text = "deep" },
		{ type = "article", text = "" },
	})
end)

T.test("'2 4' matches 1›2›3›4, 2›4, 2›3›4 but not 4›2 or 2›4›5", function()
	local function path(...)
		return vim.tbl_map(function(t)
			return { type = "heading", text = t, texts = { t } }
		end, { ... })
	end
	local toks = search._tokenize("2 4")
	T.ok(search._path_match(path("1", "2", "3", "4"), toks))
	T.ok(search._path_match(path("2", "4"), toks))
	T.ok(search._path_match(path("2", "3", "4"), toks))
	T.eq(search._path_match(path("4", "2"), toks), nil)
	T.eq(search._path_match(path("2", "4", "5"), toks), nil) -- last word must hit the section itself
	-- consecutive words may share one section
	T.ok(search._path_match(path("1.4.1 - zortex search"), search._tokenize("zortex search")))
	-- quality: exact 3 + exact 3 beats prefix/substring
	T.eq(search._path_match(path("2", "4"), toks), 6)
	T.eq(search._path_match(path("20", "x4"), toks), 3) -- prefix 2 + substring 1
end)

T.test("word order follows the hierarchy", function()
	local idx = index()
	local fwd = crumbs(sections(search.query_index(idx, "programming zortex")))
	T.ok(vim.tbl_contains(fwd, "Projects › 1 Programming › 1.4 - zortex"), vim.inspect(fwd))
	local rev = sections(search.query_index(idx, "zortex programming"))
	for _, r in ipairs(rev) do
		T.ok(r.child, "reversed order matched: " .. r.breadcrumb)
	end
end)

T.test("more words reach deeper sections", function()
	local r = crumbs(sections(search.query_index(index(), "programming zortex search")))
	T.ok(vim.tbl_contains(r, "Projects › 1 Programming › 1.4 - zortex › 1.4.1 - zortex search"), vim.inspect(r))
end)

-- ---------------------------------------------------------------------------
-- Filters, modes, display data
-- ---------------------------------------------------------------------------

T.test("token_filters: one word makes only articles and H1 headings results", function()
	for _, r in ipairs(sections(search.query_index(index(), "zortex"))) do
		if not r.child then
			local n = r.node
			T.ok(n.type == "article" or (n.type == "heading" and n.level == 1), r.breadcrumb)
		end
	end
end)

T.test("typed words ignore the depth filter", function()
	local r = crumbs(search.query_index(index(), "#zortex"))
	T.ok(vim.tbl_contains(r, "Projects › 1 Programming › 1.4 - zortex"), vim.inspect(r))
end)

T.test("direct sub-sections of a match are listed under it", function()
	local r = sections(search.query_index(index(), "programming"))
	local parent, children = nil, {}
	for _, x in ipairs(r) do
		if not parent and x.breadcrumb == "Projects › 1 Programming" then
			parent = x
		elseif parent and x.child and x.filepath == parent.filepath then
			children[#children + 1] = x.breadcrumb
		end
	end
	local i_parent = parent
	T.ok(i_parent, "parent found")
	T.eq(children, {
		"Projects › 1 Programming › 1.4 - esp32",
		"Projects › 1 Programming › 1.4 - zortex",
	})
end)

T.test("article mode matches article names; max_results caps", function()
	local r = search.query_index(index(), "a", { mode = "article" })
	T.ok(#r >= 3, "several articles contain 'a'")
	for _, x in ipairs(r) do
		T.eq(x.node.type, "article")
	end
	search.setup({ max_results = 2 })
	local ok, capped = pcall(search.query_index, index(), "a", { mode = "article" })
	search.setup()
	T.ok(ok, tostring(capped))
	T.eq(#capped, 2)
end)

T.test("text mode matches the prompt literally on every line, headings too", function()
	local r = search.query_index(index(), "1.4 - zortex", { mode = "text" })
	T.ok(#r >= 3, "heading and link lines contain it")
	for _, x in ipairs(r) do
		T.eq(x.result_type, "line")
		T.ok(x.line:lower():find("1.4 - zortex", 1, true), x.line)
		T.eq(x.line:lower():find("1.4 - zortex", 1, true), x.col)
	end
	-- the heading line is a result (section mode skips structural lines)
	local heading = vim.tbl_filter(function(x)
		return x.line:match("^## 1%.4 %- zortex") and not x.archived
	end, r)
	T.eq(#heading, 1)
	T.eq(heading[1].article_name, "Projects")
	-- live notes before archived ones
	local seen_archived = false
	for _, x in ipairs(r) do
		if x.archived then
			seen_archived = true
		else
			T.ok(not seen_archived, "live result after an archived one: " .. x.filepath)
		end
	end
	T.ok(seen_archived, "the archived copy is still found")
end)

T.test("text mode has no word syntax and uses smart case", function()
	-- words are not split: "zortex 1.4" is not on any line
	T.eq(#search.query_index(index(), "zortex 1.4", { mode = "text" }), 0)
	-- "#" and "@@" are plain characters
	local tags = search.query_index(index(), "@@car", { mode = "text" })
	T.eq(#tags, 1)
	T.eq(tags[1].line, "@@Car maintenance")
	-- a capital makes it case-sensitive
	T.eq(#search.query_index(index(), "@@CAR", { mode = "text" }), 0)
	T.eq(#search.query_index(index(), "@@Car", { mode = "text" }), 1)
	T.eq(#search.query_index(index(), "", { mode = "text" }), 0)
end)

-- ---------------------------------------------------------------------------
-- Ranking
-- ---------------------------------------------------------------------------

T.test("'p': the Projects file comes first, in document order", function()
	local r = sections(search.query_index(index(), "p"))
	T.eq(r[1].breadcrumb, "Projects") -- @@P alias: exact match on an article
	-- results of one file stay together, parents before children
	local last_line, file = 0, r[1].filepath
	for _, x in ipairs(r) do
		if x.filepath ~= file then
			break
		end
		T.ok(x.node.start_line > last_line, "document order: " .. x.breadcrumb)
		last_line = x.node.start_line
	end
end)

T.test("files are ordered by their best match", function()
	local r = sections(search.query_index(index(), "car"))
	T.eq(r[1].breadcrumb, "Flipping") -- alias "Car maintenance": prefix on an article
end)

T.test("archived notes stay searchable but come after live ones", function()
	local r = sections(search.query_index(index(), "projects"))
	T.ok(not r[1].filepath:find("archive", 1, true), r[1].filepath)
	local seen_archive = false
	for _, x in ipairs(r) do
		if x.filepath:find("archive", 1, true) then
			seen_archive = true
		else
			T.ok(not seen_archive, "live result after archive: " .. x.breadcrumb)
		end
	end
	T.ok(seen_archive, "archive still searchable")
end)

T.test("empty prompt lists top-level articles", function()
	for _, r in ipairs(sections(search.query_index(index(), ""))) do
		T.eq(r.node.type, "article")
	end
end)

T.test("the synthetic root is not part of the searchable path", function()
	T.eq(#sections(search.query_index(index(), "root")), 0)
end)

T.test("results carry a rank for the picker's order-preserving sorter", function()
	for i, x in ipairs(search.query_index(index(), "zortex")) do
		T.eq(x.rank, i)
	end
end)
