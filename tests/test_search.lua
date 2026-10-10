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
