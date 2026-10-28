local T = require("helpers")
local link = require("zortex.core.link")

T.test("links to files on this computer: ~/… and absolute paths", function()
	local home = os.getenv("HOME")
	T.eq(link.os_path("~/Documents/tax.pdf"), home .. "/Documents/tax.pdf")
	T.eq(link.os_path("[~/Documents/tax.pdf]"), home .. "/Documents/tax.pdf")
	T.eq(link.os_path("/home/me/a.pdf"), "/home/me/a.pdf")
	T.eq(link.os_path("/srv/notes"), "/srv/notes")
	-- this note's sections, not paths
	for _, def in ipairs({ "/#Heading", "/-Item", "/:Label", "/*Bold", "/%query", "/>Link", "/@Tag", "/", "~/", "P/#1", "./scan.pdf" }) do
		T.eq(link.os_path(def), nil, def)
	end
end)

T.test("links to files on this computer are never broken", function()
	local Config = require("zortex.config")
	local path = Config.notes_dir .. "os-links.zortex"
	vim.fn.writefile({
		"@@OS links",
		"",
		"- [~/Documents/tax.pdf]",
		"- [/home/nobody/plan]",
		"- [the scan](~/scans/a.png)",
		"- [/#Nowhere]",
	}, path)
	local ok, err = pcall(function()
		local index = require("zortex.core.link_index")
		local broken = vim.tbl_map(function(r)
			return r.definition or r.text
		end, index.unresolved_in(path))
		T.eq(#broken, 1, vim.inspect(broken))
		T.ok(tostring(broken[1]):find("Nowhere", 1, true), vim.inspect(broken))
	end)
	vim.fn.delete(path)
	require("zortex.core.link_index").refresh(true)
	T.ok(ok, err)
end)
