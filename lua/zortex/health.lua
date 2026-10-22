-- health.lua - :checkhealth zortex
local M = {}

function M.check()
	local health = vim.health
	local Config = require("zortex.config")
	local fs = require("zortex.utils.filesystem")

	health.start("Zortex")
	local v = vim.version()
	if vim.fn.has("nvim-0.10") == 1 then
		health.ok(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch))
	else
		health.error(string.format("Neovim %d.%d.%d: zortex needs 0.10 or newer", v.major, v.minor, v.patch))
	end
	if #vim.fn.getcompletion("zortex", "help") > 0 then
		health.ok(":help zortex")
	else
		health.warn(":help zortex is missing: doc/tags was not generated", {
			"Run :helptags ALL, or :helptags <plugin folder>/doc",
		})
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

	local conflicts = fs.find_all_notes(nil, { conflicts = true })
	if #conflicts == 0 then
		health.ok("No conflict copies from a sync tool")
	else
		local names = {}
		for i = 1, math.min(#conflicts, 5) do
			names[i] = conflicts[i]:sub(#Config.notes_dir + 1)
		end
		health.warn(
			string.format(
				"%d conflict %s (left out of the notes): %s",
				#conflicts,
				#conflicts == 1 and "copy" or "copies",
				table.concat(names, ", ")
			),
			{ "Merge each into its note by hand, then delete it" }
		)
	end

	local missing = require("zortex.core.starter").missing()
	if #missing == 0 then
		health.ok("Key notes present (calendar, projects, areas, okr, structure, inbox)")
	else
		health.warn("Missing: " .. table.concat(missing, ", "), { "`:Zortex init` creates them from short templates" })
	end

	health.info("State directory: " .. require("zortex.core.state").path(""):gsub("/%.json$", ""))

	M.check_server(health, Config)

	health.start("Zortex integrations")
	local picker = require("zortex.ui.picker").backend()
	if picker == "select" then
		health.info("Pickers: vim.ui.select (install snacks.nvim, telescope.nvim or fzf-lua for previews and keys)")
	else
		health.ok("Pickers: " .. picker .. " (ui.picker = " .. tostring(Config.ui.picker) .. ")")
	end
	if pcall(require, "blink.cmp") then
		health.ok("Link completion: blink.cmp")
	elseif pcall(require, "cmp") then
		health.ok("Link completion: nvim-cmp")
	else
		health.warn("No completion plugin (blink.cmp or nvim-cmp): no link completion")
	end
end

--- The server: reachable, with a data folder (notifications, the pomodoro)
--- and ntfy (alerts on phones and desktops).
function M.check_server(health, Config)
	health.start("Zortex server")
	local server = require("zortex.notifications.server")
	if not server.enabled() then
		health.info("server.enabled = false: notes only (no notifications, pomodoro or web app links)")
		return
	end
	local ok, body, err = server.request_sync("GET", "/healthz", nil, 3)
	if not ok then
		health.warn("Not reachable at " .. tostring((Config.server or {}).api_endpoint) .. ": " .. tostring(err), {
			"Start it: zortex serve -dir " .. Config.notes_dir .. " -data <dir> (doc/Server.md)",
			"Or point server.api_endpoint at where it runs",
		})
		return
	end
	health.ok(string.format("Reachable: %s notes, %s links", tostring(body.notes), tostring(body.links)))
	if body.data == false then
		health.warn("Started without -data: no notifications or pomodoro")
	end
	if body.ntfy == false then
		health.info("No ntfy (-ntfy-url, -ntfy-topic): alerts show in Neovim only")
	end
end

return M
