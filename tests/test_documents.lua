local T = require("helpers")
local Config = require("zortex.config")
local link = require("zortex.core.link")
local documents = require("zortex.core.documents")

local function rel_of(path)
	return documents.display_rel(path)
end

local function resolve(def)
	local results, err = link.resolve(def)
	return vim.tbl_map(function(r)
		return rel_of(r.file) .. ":" .. r.lnum
	end, results or {}), err
end

T.test("documents: the Markdown and HTML files in the folders", function()
	T.eq(documents.folders(), { "z/markdown", "z/html" })
	T.eq(documents.kind(Config.notes_dir .. "z/markdown/rust-ownership.md"), "markdown")
	T.eq(documents.kind(Config.notes_dir .. "z/html/sourdough-chemistry.html"), "html")
	T.eq(documents.kind(Config.notes_dir .. "README.md"), nil, "outside the folders")
	T.eq(documents.kind(Config.notes_dir .. "z/markdown/x.zortex"), nil)
	local rels = vim.tbl_map(rel_of, documents.paths())
	T.eq(rels, { "z/html/sourdough-chemistry.html", "z/markdown/rust-ownership.md", "z/markdown/tide-tables.md" })
	-- the page's copy is a note in .z/html
	local copy = documents.copy_path("z/html/sourdough-chemistry.html")
	T.eq(copy, Config.notes_dir .. ".z/html/z/html/sourdough-chemistry.zortex")
	T.eq(documents.source_of(copy), Config.notes_dir .. "z/html/sourdough-chemistry.html")
	local lines = vim.fn.readfile(copy)
	T.eq(vim.list_slice(lines, 1, 6), {
		"@@The Chemistry of Sourdough",
		"@@sourdough-chemistry",
		"",
		"From [z/html/sourdough-chemistry.html](/raw/z/html/sourdough-chemistry.html)",
		"",
		"# The Chemistry of Sourdough",
	})
end)

T.test("documents: a Markdown file reads as a note, line for line", function()
	local doc = require("zortex.core.document").get(Config.notes_dir .. "z/markdown/rust-ownership.md")
	T.eq(doc.names, { "Rust Ownership", "Ownership", "rust-ownership" })
	T.eq(doc.tags, { "rust", "lang" })
	T.eq(#doc.lines, #vim.fn.readfile(Config.notes_dir .. "z/markdown/rust-ownership.md"))
	T.eq(doc.lines[1], "", "front matter reads as blank")
	T.eq(doc.lines[8], "# Rust Ownership", "closing #s dropped")
	T.eq(doc.lines[12], "## Borrowing", "{#id} dropped")
	T.eq(doc.lines[20], "## Lifetimes", "setext heading")
	T.eq(doc.lines[21], "")
	local tide = require("zortex.core.document").get(Config.notes_dir .. "z/markdown/tide-tables.md")
	T.eq(tide.names, { "Tide Tables", "tide-tables" }, "named by its first # heading")
end)

T.test("documents: links reach their headings; a note wins a name", function()
	T.eq(resolve("[Rust Ownership/#Borrowing]"), { "z/markdown/rust-ownership.md:12" })
	T.eq(resolve("[Ownership/#Borrowing/#Mutable]"), { "z/markdown/rust-ownership.md:16" })
	T.eq(resolve("[rust-ownership/#Lifetimes]"), { "z/markdown/rust-ownership.md:20" })
	T.eq(resolve("[Tide Tables/#Neap]"), { "z/markdown/tide-tables.md:9" })
	T.eq(resolve("[The Chemistry of Sourdough/#Gluten]"), { "z/html/sourdough-chemistry.html:19" })
	T.eq(resolve("[sourdough-chemistry/#The starter/-acetic]"), { "z/html/sourdough-chemistry.html:17" })
	T.eq(resolve("[Rust Ownership]"), { "z/markdown/rust-ownership.md:1" })
	local _, err = resolve("[Rust Ownership/#Nowhere]")
	T.ok(err and err:match("Nowhere"), err)
	-- the copy is what Neovim opens
	local r = link.resolve("[sourdough-chemistry/#Gluten]")[1]
	T.eq(r.file, Config.notes_dir .. ".z/html/z/html/sourdough-chemistry.zortex")
	-- a note with the same name comes first
	local path = Config.notes_dir .. "tide-note.zortex"
	vim.fn.writefile({ "@@Tide Tables", "", "# Neap", "" }, path)
	require("zortex.core.notes").invalidate()
	local ok, e = pcall(function()
		T.eq(resolve("[Tide Tables/#Neap]"), { "tide-note.zortex:3", "z/markdown/tide-tables.md:9" })
	end)
	vim.fn.delete(path)
	require("zortex.core.notes").invalidate()
	T.ok(ok, e)
end)

T.test("documents: in the search, not in projects or broken links", function()
	local search = require("zortex.services.search")
	local found = {}
	for _, r in ipairs(search.search("spring tides", { mode = "section" })) do
		local node = r.section_node or r.node
		found[#found + 1] = rel_of(r.filepath) .. ":" .. (r.lnum or (node and node.start_line) or 0)
	end
	T.ok(vim.tbl_contains(found, "z/markdown/tide-tables.md:5"), vim.inspect(found))
	local text = {}
	for _, r in ipairs(search.search("gluten forms a net", { mode = "text" })) do
		text[#text + 1] = rel_of(r.filepath or r.file)
	end
	T.ok(vim.tbl_contains(text, "z/html/sourdough-chemistry.html"), vim.inspect(text))
	-- not notes: the project lists, XP and the rest don't see them
	for _, p in ipairs(require("zortex.core.notes").files({ include_archived = true })) do
		T.ok(not documents.is_document(p), p)
	end
	-- a note linking them: broken only where the heading isn't there
	local path = Config.notes_dir .. "doc-links.zortex"
	vim.fn.writefile({
		"@@Doc links",
		"",
		"- [Rust Ownership/#Borrowing]",
		"- [sourdough-chemistry/#Gluten]",
		"- [Tide Tables/#King tides]",
	}, path)
	local index = require("zortex.core.link_index")
	index.refresh(true)
	local ok, e = pcall(function()
		local broken = index.unresolved_in(path)
		T.eq(#broken, 1, vim.inspect(broken))
		T.eq(broken[1].lnum, 5)
		-- their own [brackets] aren't links that can break
		for _, b in ipairs(index.unresolved()) do
			T.ok(not documents.is_document(b.file or b.filepath or ""), vim.inspect(b))
		end
	end)
	vim.fn.delete(path)
	index.refresh(true)
	T.ok(ok, e)
end)

T.test("documents: a changed page's copy follows; Neovim opens it read-only", function()
	local page = Config.notes_dir .. "z/html/new-page.html"
	vim.fn.writefile({ "<title>New page</title><h2>First</h2><p>one</p>" }, page)
	require("zortex.core.notes").invalidate()
	local ok, e = pcall(function()
		T.eq(resolve("[New page/#First]"), { "z/html/new-page.html:6" })
		vim.fn.writefile({ "<title>New page</title><p>intro</p><h2>Second</h2>" }, page)
		vim.uv.fs_utime(page, os.time() + 5, os.time() + 5)
		require("zortex.core.notes").invalidate()
		T.eq(resolve("[New page/#Second]"), { "z/html/new-page.html:8" })
		local copy = documents.copy_path("z/html/new-page.html")
		documents.setup()
		vim.cmd.edit(vim.fn.fnameescape(copy))
		T.ok(vim.bo.readonly and not vim.bo.modifiable, "read-only")
		vim.cmd("bwipeout!")
	end)
	vim.fn.delete(page)
	vim.fn.delete(documents.copy_path("z/html/new-page.html"))
	require("zortex.core.notes").invalidate()
	T.ok(ok, e)
end)

T.test("documents: other folders, or none", function()
	local saved = Config.documents
	Config.documents = { "z/markdown/" }
	require("zortex.core.notes").invalidate()
	local ok, e = pcall(function()
		T.eq(vim.tbl_map(rel_of, documents.paths()), { "z/markdown/rust-ownership.md", "z/markdown/tide-tables.md" })
		Config.documents = {}
		require("zortex.core.notes").invalidate()
		require("zortex.core.document").invalidate()
		T.eq(documents.paths(), {})
		local _, err = resolve("[Rust Ownership]")
		T.ok(err, "no documents: no match")
	end)
	Config.documents = saved
	require("zortex.core.notes").invalidate()
	require("zortex.core.document").invalidate()
	T.ok(ok, e)
end)

T.test("documents: the web app's page for one, and the folders in .z/syntax.json", function()
	local web = require("zortex.features.web")
	T.eq(web.note_path(Config.notes_dir .. "z/markdown/rust-ownership.md", 12), "/f/z/markdown/rust-ownership.md#L12")
	T.eq(
		web.note_path(documents.copy_path("z/html/sourdough-chemistry.html"), 19),
		"/f/z/html/sourdough-chemistry.html?view=readable#L19"
	)
	T.eq(web.note_path(Config.notes_dir .. "projects.zortex", 3), "/n/projects.zortex#L3")
	-- completion offers their names, and their headings after one
	local C = require("zortex.features.completion")
	local labels = {}
	for _, i in ipairs(C.get_completions("[Rust", 5, { bufnr = 0, lnum = 1 }) or {}) do
		labels[i.label] = true
	end
	T.ok(labels["Rust Ownership"], vim.inspect(vim.tbl_keys(labels)))
	labels = {}
	for _, i in ipairs(C.get_completions("[Rust Ownership/#", 17, { bufnr = 0, lnum = 1 }) or {}) do
		labels[i.label] = true
	end
	T.ok(labels["#Borrowing"] or labels["#Rust Ownership"], vim.inspect(vim.tbl_keys(labels)))
	local saved = Config.documents
	local sc = require("zortex.core.syntax_config")
	local State = require("zortex.core.state")
	local ok, e = pcall(function()
		sc.setup({}, nil, Config.documents)
		local path = State.path("syntax")
		local before = vim.fn.filereadable(path) == 1 and vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) or {}
		T.eq(before.documents, nil, "the default needs no saying")
		Config.documents = { "docs" }
		sc.setup({}, nil, Config.documents)
		T.eq(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).documents, { "docs" })
		Config.documents = {}
		sc.setup({}, nil, Config.documents)
		T.eq(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).documents, {})
	end)
	Config.documents = saved
	sc.setup({}, nil, Config.documents)
	T.ok(ok, e)
end)
