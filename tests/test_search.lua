local T = require("helpers")
local search = require("zortex.ui.telescope.search")
local fs = require("zortex.utils.filesystem")

local function crumbs(results)
	return vim.tbl_map(function(r)
		return r.breadcrumb or r.line
	end, results)
end

T.test("setup overlays user options on the defaults", function()
	local cfg = search.setup({ max_results = 7, history = { enabled = false } })
	T.eq(cfg.max_results, 7)
	T.eq(cfg.default_mode, "section") -- untouched default
	T.eq(cfg.history.enabled, false)
	T.eq(cfg.history.max_entries, 50) -- sibling default kept
	T.ok(cfg.token_filters[1], "token filters present")
	-- defaults are not mutated
	T.eq(require("zortex.config").defaults.ui.search.max_results, 500)
end)

T.test("token_filters: one token matches articles and H1 only", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	for _, r in ipairs(search.query_index(idx, "zortex")) do
		if r.result_type == "section" then
			local n = r.node
			T.ok(n.type == "article" or (n.type == "heading" and n.level == 1), r.breadcrumb)
		end
	end
end)

T.test("more tokens search deeper", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local deep = crumbs(search.query_index(idx, "zortex search project"))
	T.ok(vim.tbl_contains(deep, "Projects › 1 Programming › 1.4 - zortex › 1.4.1 - zortex search"), vim.inspect(deep))
end)

T.test("typed tokens ignore the depth filter", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local r = crumbs(search.query_index(idx, "#zortex"))
	T.ok(vim.tbl_contains(r, "Projects › 1 Programming › 1.4 - zortex"), vim.inspect(r))
end)

T.test("article mode and max_results", function()
	search.setup({ max_results = 2 })
	local idx = search.build_index(fs.find_all_notes())
	local r = search.query_index(idx, "zortex", { mode = "article" })
	T.eq(#r, 2)
	for _, x in ipairs(r) do
		T.eq(x.node.type, "article")
	end
	search.setup()
end)

local function sections(results)
	return vim.tbl_filter(function(r)
		return r.result_type == "section"
	end, results)
end

T.test("ranking: 'p' lists articles named P… first, articles before headings", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local r = sections(search.query_index(idx, "p"))
	T.eq(r[1].breadcrumb, "Projects") -- name and @@P alias start with p
	T.eq(r[2].breadcrumb, "Flipping") -- article containing p
	-- Own-name matches: every article precedes every heading
	local seen_heading = false
	for _, x in ipairs(r) do
		if x.rank_key.tier == 0 then
			if x.node.type == "heading" then
				seen_heading = true
			else
				T.ok(not seen_heading, "article after heading: " .. x.breadcrumb)
			end
		end
	end
	-- Content-only matches come after all name matches
	local last_tier = -1
	for _, x in ipairs(r) do
		T.ok(x.rank_key.tier >= last_tier, "tiers out of order at " .. x.breadcrumb)
		last_tier = x.rank_key.tier
	end
end)

T.test("ranking: prefix beats word start beats inside a word", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local r = sections(search.query_index(idx, "car"))
	-- "Car maintenance" is an alias of Flipping: prefix match on an article
	T.eq(r[1].breadcrumb, "Flipping")
end)

T.test("ranking: parent heading before children sharing its text", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local r = sections(search.query_index(idx, "#zortex"))
	local pos = {}
	for i, x in ipairs(r) do
		pos[x.breadcrumb] = pos[x.breadcrumb] or i
	end
	local parent = pos["Projects › 1 Programming › 1.4 - zortex"]
	local child = pos["Projects › 1 Programming › 1.4 - zortex › 1.4.1 - zortex search"]
	T.ok(parent and child and parent < child, vim.inspect(pos))
end)

T.test("the synthetic root is not part of the searchable path", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	T.eq(#sections(search.query_index(idx, "root")), 0)
end)

T.test("results carry a rank for the picker's order-preserving sorter", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	for i, x in ipairs(search.query_index(idx, "zortex")) do
		T.eq(x.rank, i)
	end
end)

T.test("archived notes stay searchable but rank after live ones", function()
	search.setup()
	local idx = search.build_index(fs.find_all_notes())
	local r = sections(search.query_index(idx, "projects"))
	T.ok(not r[1].filepath:find("archive", 1, true), r[1].filepath)
	local found_archive = false
	for _, x in ipairs(r) do
		found_archive = found_archive or x.filepath:find("archive", 1, true) ~= nil
	end
	T.ok(found_archive, "archive still searchable")
end)
