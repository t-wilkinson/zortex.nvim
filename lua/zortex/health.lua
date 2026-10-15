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

	M.check_ntfy(health, Config)

	health.start("Zortex integrations")
	for _, dep in ipairs({ { "telescope", "search and project pickers" }, { "cmp", "link completion" } }) do
		if pcall(require, dep[1]) then
			health.ok(dep[1] .. " (" .. dep[2] .. ")")
		else
			health.warn(dep[1] .. " not found: no " .. dep[2])
		end
	end
end

--- ntfy: a topic is required and must be private (anyone who knows a
--- topic on a public server can read it).
function M.check_ntfy(health, Config)
	local ntfy = vim.tbl_get(Config, "notifications", "providers", "ntfy")
	if not (ntfy and ntfy.enabled) then
		return
	end
	health.start("Zortex notifications (ntfy)")
	local topic = type(ntfy.topic) == "string" and vim.trim(ntfy.topic) or ""
	if topic == "" then
		health.warn("ntfy is enabled but has no topic: nothing is sent", {
			"Set notifications.providers.ntfy.topic to a private, hard-to-guess name",
		})
	elseif topic == "zortex-notify" then
		health.warn("ntfy topic is zortex-notify, the old shared default: anyone can read it", {
			"Pick a private, hard-to-guess topic (and the same in the server's NTFY_TOPIC)",
		})
	else
		health.ok("ntfy topic set (" .. (ntfy.server_url or "https://ntfy.sh") .. ")")
	end
	if type(ntfy.server_url) == "string" and ntfy.server_url:match("^http://") then
		health.warn("ntfy server_url is plain http: notifications travel unencrypted", { "Use https://" })
	end
end

return M
