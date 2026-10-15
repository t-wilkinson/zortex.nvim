-- The picker interface (ui/picker) and completion registration, with stub
-- plugins (tests/test_zzz_integrations.lua runs the real ones).
local T = require("helpers")
local Picker = require("zortex.ui.picker")
local Config = require("zortex.config")

Config.ui = Config.ui or {}

-- Make `mods` loadable (or not) while fn runs
local function with_modules(mods, fn)
	local saved, saved_g = {}, vim.g.lazyvim_picker
	local blocked = {}
	for name, value in pairs(mods) do
		saved[name] = package.loaded[name]
		if value == false then
			blocked[name] = true
			package.loaded[name] = nil
		else
			package.loaded[name] = value
		end
	end
	local loader = function(name)
		if blocked[name] then
			return function()
				error("blocked " .. name)
			end
		end
	end
	table.insert(package.loaders, 1, loader)
	local ok, err = pcall(fn)
	table.remove(package.loaders, 1)
	for name in pairs(mods) do
		package.loaded[name] = saved[name]
	end
	vim.g.lazyvim_picker = saved_g
	Config.ui.picker = nil
	assert(ok, err)
end

local NONE = { ["telescope.pickers"] = false, snacks = false, ["fzf-lua"] = false }

T.test("auto: vim.ui.select when no picker plugin is installed", function()
	with_modules(NONE, function()
		T.eq(Picker.backend(), "select")
	end)
end)

T.test("auto: telescope, then fzf-lua, then snacks; an enabled snacks.picker first", function()
	local mods = vim.deepcopy(NONE)
	mods["fzf-lua"] = {}
	mods.snacks = { picker = {}, config = { picker = { enabled = false } } }
	with_modules(mods, function()
		T.eq(Picker.backend(), "fzf_lua")
	end)
	mods["telescope.pickers"] = {}
	with_modules(mods, function()
		T.eq(Picker.backend(), "telescope")
	end)
	mods.snacks.config.picker.enabled = true
	with_modules(mods, function()
		T.eq(Picker.backend(), "snacks")
	end)
end)

T.test("auto follows LazyVim's picker; ui.picker names one", function()
	local mods = { ["telescope.pickers"] = {}, snacks = { picker = {} }, ["fzf-lua"] = {} }
	with_modules(mods, function()
		vim.g.lazyvim_picker = "fzf"
		T.eq(Picker.backend(), "fzf_lua")
		vim.g.lazyvim_picker = "snacks"
		T.eq(Picker.backend(), "snacks")
		Config.ui.picker = "telescope"
		T.eq(Picker.backend(), "telescope")
	end)
	with_modules(NONE, function()
		Config.ui.picker = "snacks" -- not installed
		T.eq(Picker.backend(), "select")
	end)
end)

T.test("fzf-lua key names", function()
	local F = require("zortex.ui.picker.fzf_lua")
	T.eq(F.fzf_key("<C-l>"), "ctrl-l")
	T.eq(F.fzf_key("<M-t>"), "alt-t")
	T.eq(F.fzf_key("<A-s>"), "alt-s")
end)

T.test("confirm: one item opens; several go to the quickfix list and the first opens", function()
	local opened, recorded = {}, {}
	local spec = {
		title = "Things",
		format = function(i)
			return { { i.name } }
		end,
		location = function(i)
			return { file = T.fixture("projects.zortex"), lnum = i.lnum, text = i.name }
		end,
		open = function(i, cmd)
			opened[#opened + 1] = i.name .. ":" .. cmd
		end,
		on_open = function(i)
			recorded[#recorded + 1] = i.name
		end,
	}
	Picker.confirm(spec, { { name = "a", lnum = 1 } }, "vsplit")
	T.eq(opened, { "a:vsplit" })
	T.eq(recorded, { "a" })
	opened, recorded = {}, {}
	Picker.confirm(spec, { { name = "a", lnum = 1 }, { name = "b", lnum = 7 } })
	T.eq(opened, { "a:edit" })
	T.eq(recorded, { "a", "b" })
	local qf = vim.fn.getqflist({ title = 1, items = 1 })
	T.eq(qf.title, "Things")
	T.eq(vim.tbl_map(function(e)
		return e.lnum .. " " .. e.text
	end, qf.items), { "1 a", "7 b" })
	vim.cmd("cclose")
	vim.fn.setqflist({}, "f")
end)

T.test("render joins segments with highlight ranges", function()
	local text, hls = Picker.render({
		format = function()
			return { { "Rust", "ZortexArticle" }, { " › " }, { "" , "X" }, { "Async", "Comment" } }
		end,
	}, {})
	T.eq(text, "Rust › Async")
	T.eq(hls, { { { 0, 4 }, "ZortexArticle" }, { { #"Rust › ", #text }, "Comment" } })
end)

T.test("the search picker's spec: live, in services/search's order", function()
	local spec = require("zortex.ui.picker.search").spec({ mode = "section" })
	local results = spec.query("rust")
	T.ok(#results > 0)
	T.eq(results, require("zortex.services.search").query_index(
		require("zortex.services.search").build_index(require("zortex.services.search").files()),
		"rust",
		{ mode = "section" }
	))
	local first = results[1]
	local text = Picker.render(spec, first)
	T.ok(text:find("Rust", 1, true), text)
	local p = spec.preview(first)
	T.ok(p.zortex and p.lnum and #p.lines > 0)
	T.ok(spec.title():find("(section)", 1, true))
	spec.keys["<M-t>"].fn()
	T.ok(spec.title():find("(article)", 1, true), spec.title())
end)

T.test("blink.cmp registration: one provider, listed for zortex buffers, yours kept", function()
	local added, filetypes = {}, {}
	local providers = {}
	local blink = {
		add_source_provider = function(id, cfg)
			assert(not providers[id], "Provider with id " .. id .. " already exists")
			providers[id] = cfg
			added[#added + 1] = id
		end,
		add_filetype_source = function(ft, id)
			filetypes[#filetypes + 1] = ft .. ":" .. id
		end,
	}
	local C = require("zortex.features.completion")
	C._blink_filetype = nil
	with_modules({ ["blink.cmp"] = blink, ["blink.cmp.config"] = { sources = { providers = providers } } }, function()
		T.eq(C.register(), "blink")
		T.eq(C.register(), "blink")
		T.eq(added, { "zortex" })
		T.eq(filetypes, { "zortex:zortex" })
		T.eq(providers.zortex.module, "zortex.features.blink")
	end)
	-- a provider of your own is left alone
	C._blink_filetype = nil
	added = {}
	local mine = { zortex = { module = "zortex.features.blink", score_offset = 5 } }
	with_modules({ ["blink.cmp"] = blink, ["blink.cmp.config"] = { sources = { providers = mine } } }, function()
		C.register_blink()
		T.eq(added, {})
		T.eq(mine.zortex.score_offset, 5)
	end)
	C._blink_filetype = nil
end)

T.test("nvim-cmp registration lists the source for zortex buffers next to yours", function()
	local filetype_cfg
	local cmp = {
		register_source = function()
			return 1
		end,
		setup = {
			filetype = function(ft, cfg)
				filetype_cfg = { ft = ft, cfg = cfg }
			end,
		},
	}
	local cmp_config = {
		filetypes = {},
		global = { sources = { { name = "nvim_lsp" }, { name = "buffer" } }, sorting = { comparators = {} } },
	}
	local C = require("zortex.features.completion")
	C._cmp_id, C._cmp_sources = nil, nil
	with_modules({ ["blink.cmp"] = false, cmp = cmp, ["cmp.config"] = cmp_config }, function()
		T.eq(C.register(), "cmp")
		T.eq(filetype_cfg.ft, "zortex")
		T.eq(vim.tbl_map(function(s)
			return s.name
		end, filetype_cfg.cfg.sources), { "zortex", "nvim_lsp", "buffer" })
		-- your own sources for zortex buffers stay
		cmp_config.filetypes.zortex = { sources = { { name = "buffer" } } }
		C.register_cmp()
		T.eq(filetype_cfg.cfg.sources, { { name = "buffer" } })
	end)
	C._cmp_id, C._cmp_sources = nil, nil
end)
