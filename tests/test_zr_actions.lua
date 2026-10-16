local T = require("helpers")
local actions = require("zortex.actions")

T.test("every action is complete and its target exists", function()
	local ids, commands, keys = {}, {}, {}
	for _, a in ipairs(actions.list) do
		T.ok(a.id and a.desc and a.group and type(a.run) == "function", vim.inspect(a))
		T.ok(not ids[a.id], "duplicate id " .. a.id)
		ids[a.id] = true
		if a.command then
			T.ok(not commands[a.command], "duplicate command " .. a.command)
			commands[a.command] = true
		end
		for _, k in ipairs(type(a.key) == "table" and a.key or { a.key }) do
			T.ok(not keys[k], "duplicate key " .. tostring(k))
			keys[k] = true
		end
		if a.target then
			local ok, mod = pcall(require, a.target.module)
			T.ok(ok, a.id .. ": cannot load " .. a.target.module .. ": " .. tostring(mod))
			T.eq(type(mod[a.target.fn]), "function", a.id .. " -> " .. a.target.module .. "." .. a.target.fn)
		end
	end
end)

T.test("commands and keymaps come from the list, with overrides", function()
	actions.create_commands("ZtTest")
	T.eq(vim.fn.exists(":ZtTestReview"), 2)
	-- Lua commands keep their description in `desc` on Neovim 0.12+, in
	-- `definition` before
	local cmd = vim.api.nvim_get_commands({})["ZtTestBacklinks"]
	local desc = (cmd.desc and cmd.desc ~= "") and cmd.desc or cmd.definition
	T.eq(desc, "Links into the section under the cursor (quickfix)")
	actions.create_keymaps("<leader>q", { task_toggle = "t", search = false, review = { "w", "R" } })
	T.eq(vim.fn.maparg("<leader>qt", "n", false, true).desc, "Toggle the task on this line (makes one if needed); on a project heading, mark the project done")
	T.eq(vim.fn.maparg("<leader>qz", "n"), "")
	T.ok(vim.fn.maparg("<leader>qR", "n", false, true).callback, "list override")
	local help = table.concat(actions.help_lines(), "\n")
	T.ok(help:find("# Links", 1, true) and help:find(":ZortexBacklinks", 1, true), help)
end)

T.test("key prefixes are named for which-key", function()
	local groups = {}
	for _, g in ipairs(actions.key_groups("<leader>z", {}, { C = "Calendar & digest" })) do
		groups[g[1]] = g[2]
	end
	T.eq(groups["<leader>z"], "Zortex")
	T.eq(groups["<leader>zC"], "Calendar & digest") -- named in config
	T.eq(groups["<leader>zx"], "XP") -- named after its actions' group
	T.eq(groups["<leader>zt"], "Tasks")
	T.eq(groups["<leader>zz"], nil) -- a single key, not a prefix

	-- overrides: a remapped action makes its prefix, false skips a name
	local custom = {}
	for _, g in ipairs(actions.key_groups("<leader>q", { review = "ra", xp_stats = false }, { x = false })) do
		custom[g[1]] = g[2]
	end
	T.eq(custom["<leader>qr"], "Plan")
	T.eq(custom["<leader>qx"], nil)
end)

T.test("which-key gets the groups when installed (v3 add, v2 register)", function()
	local saved = package.loaded["which-key"]
	if not saved and not pcall(require, "which-key") then
		T.eq(actions.register_which_key("<leader>z", {}, {}), false) -- not installed: nothing to do
	end

	local added
	package.loaded["which-key"] = {
		add = function(spec)
			added = spec
		end,
	}
	T.ok(actions.register_which_key("<leader>z", {}, { C = "Calendar & digest" }))
	local by_lhs = {}
	for _, s in ipairs(added) do
		by_lhs[s[1]] = s
	end
	T.eq(by_lhs["<leader>z"].group, "Zortex")
	T.eq(by_lhs["<leader>zC"].group, "Calendar & digest")
	T.eq(by_lhs["<leader>zC"].mode, "n")

	local registered
	package.loaded["which-key"] = {
		register = function(spec, opts)
			registered = { spec = spec, opts = opts }
		end,
	}
	T.ok(actions.register_which_key("<leader>z", {}, {}))
	T.eq(registered.spec["<leader>zo"].name, "+Pomodoro")
	T.eq(registered.opts.mode, "n")
	package.loaded["which-key"] = saved
end)

T.test("api exposes services lazily and actions by id", function()
	local z = require("zortex")
	T.eq(z.projects, require("zortex.services.projects"))
	T.eq(z.query, require("zortex.query"))
	T.eq(type(z.actions.review), "function")
	T.eq(z.actions.nope, nil)
	for name, path in pairs(z.SERVICES) do
		T.ok(pcall(require, path), name .. " -> " .. path)
	end
end)

T.test("backlinks action fills the quickfix list", function()
	vim.cmd("edit! " .. vim.fn.fnameescape(T.fixture("projects.zortex")))
	vim.api.nvim_win_set_cursor(0, { 15, 0 }) -- "## 1.4 - zortex"
	actions.run("backlinks")
	local qf = vim.fn.getqflist({ title = 1, items = 1 })
	T.ok(qf.title:find("1.4 - zortex", 1, true), qf.title)
	T.ok(#qf.items >= 3, "references: " .. #qf.items)
	vim.cmd("cclose")
	vim.cmd("bwipeout!")
end)

T.test("README command table is up to date", function()
	local gen = dofile(T.root .. "/tests/gen_docs.lua")
	local lines = vim.fn.readfile(gen.readme)
	T.ok(vim.tbl_contains(lines, gen.START), "README has the actions block")
	T.eq(gen.render_readme(lines), lines, "regenerate with: nvim --headless -u NONE -l tests/gen_docs.lua")
end)

T.test(":help zortex is up to date and its tags are valid", function()
	local gen = dofile(T.root .. "/tests/gen_docs.lua")
	T.eq(gen.vimdoc_lines(), vim.fn.readfile(gen.vimdoc), "regenerate with: nvim --headless -u NONE -l tests/gen_docs.lua")
	local dir = vim.fn.tempname() .. "/doc"
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile(vim.fn.readfile(gen.vimdoc), dir .. "/zortex.txt")
	vim.cmd("helptags " .. vim.fn.fnameescape(dir)) -- errors on duplicate tags
	local tags = table.concat(vim.fn.readfile(dir .. "/tags"), "\n")
	for _, tag in ipairs({ "zortex", "zortex-config", ":ZortexSearch", ":ZortexInit", "zortex-action-pomodoro_toggle" }) do
		T.ok(tags:find(tag .. "\t", 1, true), tag)
	end
end)
