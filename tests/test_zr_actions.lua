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
	T.eq(vim.api.nvim_get_commands({})["ZtTestBacklinks"].definition, "Links into the section under the cursor (quickfix)")
	actions.create_keymaps("<leader>q", { task_toggle = "t", search = false, review = { "w", "R" } })
	T.eq(vim.fn.maparg("<leader>qt", "n", false, true).desc, "Zortex: Toggle the task on this line (makes one if needed)")
	T.eq(vim.fn.maparg("<leader>qz", "n"), "")
	T.ok(vim.fn.maparg("<leader>qR", "n", false, true).callback, "list override")
	local help = table.concat(actions.help_lines(), "\n")
	T.ok(help:find("# Links", 1, true) and help:find(":ZortexBacklinks", 1, true), help)
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
