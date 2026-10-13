-- health.lua - :checkhealth zortex
local M = {}

function M.check()
	local health = vim.health
	local Config = require("zortex.config")

	health.start("Zortex")
	local v = vim.version()
	if vim.fn.has("nvim-0.10") == 1 then
		health.ok(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch))
	else
		health.error(string.format("Neovim %d.%d.%d: zortex needs 0.10 or newer", v.major, v.minor, v.patch))
	end
	local dir = Config.notes_dir
	if dir and vim.fn.isdirectory(dir) == 1 then
		health.ok("notes_dir: " .. dir)
	else
		health.error(
			"notes_dir does not exist: " .. tostring(dir),
			{ "Set notes_dir in require('zortex').setup({...})" }
		)
		return
	end

	local ok, files = pcall(require("zortex.core.notes").files)
	if ok then
		health.ok(string.format("%d notes indexed", #files))
	else
		health.error("Notes index failed: " .. tostring(files))
	end

	for _, name in ipairs({ "projects", "areas", "okr" }) do
		local mod = require("zortex.services." .. name)
		local list_ok, list = pcall(name == "okr" and mod.objectives or mod.all)
		if list_ok then
			health.ok(string.format("%s: %d", name, #list))
		else
			health.warn(string.format("%s failed: %s", name, tostring(list)))
		end
	end

	local broken_ok, broken = pcall(require("zortex.core.link_index").unresolved)
	if broken_ok then
		if #broken == 0 then
			health.ok("No broken links")
		else
			health.warn(string.format("%d broken links", #broken), { ":ZortexBrokenLinks lists them" })
		end
	end

	local missing = require("zortex.core.starter").missing()
	if #missing == 0 then
		health.ok("Key notes present (calendar, projects, areas, okr, structure, inbox)")
	else
		health.warn("Missing: " .. table.concat(missing, ", "), { ":ZortexInit creates them from short templates" })
	end

	health.info("State directory: " .. require("zortex.core.state").path(""):gsub("/%.json$", ""))

	health.start("Zortex integrations")
	for _, dep in ipairs({ { "telescope", "search and project pickers" }, { "cmp", "link completion" } }) do
		if pcall(require, dep[1]) then
			health.ok(dep[1] .. " (" .. dep[2] .. ")")
		else
			health.warn(dep[1] .. " not found: no " .. dep[2])
		end
	end
end

return M
