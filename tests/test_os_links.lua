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

T.test("the web app's addresses of files are links to them", function()
	T.eq(link.site_path("/raw/z/books/a%20b.pdf"), "z/books/a b.pdf")
	T.eq(link.site_path("[/f/z/books/]"), "z/books")
	T.eq(link.site_path("/n/projects.zortex#L3"), "projects.zortex")
	T.eq(link.site_path("/home/me/a.pdf"), nil)
	T.eq(link.os_path("/raw/z/a.pdf"), nil, "not a file elsewhere on the computer")
	local Config = require("zortex.config")
	T.eq(link.relative_path("/raw/z/a.pdf", Config.notes_dir .. "x.zortex"), vim.fn.simplify(Config.notes_dir .. "/z/a.pdf"))
	-- broken only when the file isn't there
	local path = Config.notes_dir .. "site-links.zortex"
	vim.fn.writefile({ "@@Site links", "", "- [/n/projects.zortex]", "- [/f/z/]", "- [/raw/z/nothing.pdf]" }, path)
	local ok, err = pcall(function()
		local broken = require("zortex.core.link_index").unresolved_in(path)
		T.eq(#broken, 1, vim.inspect(broken))
		T.eq(broken[1].lnum, 5)
	end)
	vim.fn.delete(path)
	require("zortex.core.link_index").refresh(true)
	T.ok(ok, err)
end)
