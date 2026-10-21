-- features/markdown_import: Markdown files to notes
local T = require("helpers")
local MI = require("zortex.features.markdown_import")
local syntax = require("zortex.core.syntax")

local function convert(lines, opts)
	return (MI.convert(lines, opts))
end

T.test("front matter becomes the header; a lone # Title is the name", function()
	local out = convert({
		"---",
		"title: Sourdough",
		"aliases: [Bread, Levain]",
		"tags:",
		"  - baking",
		"  - projects/home",
		"created: 2024-01-05",
		"source: The Book (2nd ed.)",
		"nested:",
		"  key: value",
		"---",
		"# Sourdough",
		"",
		"Feed the starter.",
	})
	T.eq(out, {
		"@@Sourdough",
		"@@Bread",
		"@@Levain",
		"@baking",
		"@projects-home",
		"@created(2024-01-05)",
		"",
		"```yaml",
		"source: The Book (2nd ed.)",
		"nested:",
		"  key: value",
		"```",
		"",
		"Feed the starter.",
	})
	T.eq(syntax.parse_header(out).names, { "Sourdough", "Bread", "Levain" })
	-- no front matter: a lone first H1 is the name; else the file's name
	T.eq(convert({ "# Garden", "", "## Beds", "text" }), { "@@Garden", "", "## Beds", "text" })
	T.eq(convert({ "# One", "# Two" }, { name = "notes" }), { "@@notes", "", "# One", "# Two" })
	T.eq(convert({ "Title", "=====", "", "Body" }, { name = "x" })[1], "@@Title")
end)

T.test("blocks: setext, rules, bullets, indented code, tables, quotes, callouts", function()
	local out = convert({
		"Intro line",
		"",
		"Section",
		"-------",
		"",
		"* star",
		"+ plus",
		"1) one",
		"- [X] done",
		"",
		"***",
		"- - -",
		"",
		"    code here",
		"    more",
		"",
		"a | b",
		"--|:-:",
		"1 | 2",
		"",
		">quoted",
		">",
		"> [!warning]- Careful",
		"> body",
		"",
		"## Heading ##",
		"### Id {#custom-id}",
		"",
		"```md",
		"* not converted",
		"```",
	}, { name = "Blocks" })
	T.eq(out, {
		"@@Blocks",
		"",
		"Intro line",
		"",
		"## Section",
		"",
		"- star",
		"- plus",
		"1. one",
		"- [X] done",
		"",
		"---",
		"---",
		"",
		"```",
		"code here",
		"more",
		"```",
		"",
		"| a | b |",
		"| --|:-: |",
		"| 1 | 2 |",
		"",
		"> quoted",
		"",
		"> **Warning:** Careful",
		"> body",
		"",
		"## Heading",
		"### Id",
		"",
		"```md",
		"* not converted",
		"```",
	})
	for _, l in ipairs({ "---", "| a | b |", "| --|:-: |", "> **Warning:** Careful" }) do
		T.ok(({ rule = 1, table = 1, quote = 1 })[syntax.classify(l).kind], l .. ": " .. syntax.classify(l).kind)
	end
	-- a list item's indented lines aren't code
	T.eq(convert({ "- item", "", "    continued" }, { name = "x" })[5], "    continued")
end)

T.test("inline: links, images, emphasis and tags; code is left alone", function()
	local notes = {
		["sourdough"] = { name = "Sourdough", headings = { { text = "Method", slug = "method" } } },
		["guide"] = { name = "The Guide", headings = {} },
	}
	local opts = {
		name = "x",
		resolve = function(t)
			return notes[t:gsub("%.md$", ""):lower()]
		end,
		file = function(n)
			return n == "pic.png" and "./attachments/pic.png" or nil
		end,
	}
	local function one(line)
		return convert({ line }, opts)[3]
	end
	T.eq(one("See [[Sourdough]] and [[Sourdough#Method]]."), "See [Sourdough] and [Sourdough/#Method].")
	T.eq(one("My [[Sourdough|bread notes]] here"), "My bread notes [Sourdough] here")
	T.eq(one("Block [[Sourdough#^abc123]]"), "Block [Sourdough]")
	T.eq(one("Local [[#Method]]"), "Local [/#Method]")
	T.eq(one("Unknown [[Some Note]]"), "Unknown [Some Note]")
	T.eq(one("[this guide](guide.md) and [Sourdough](./sourdough.md#method)"), "this guide [The Guide] and [Sourdough/#Method]")
	T.eq(one("[the guide](guide.md)"), "[The Guide]", "the text is the name: the link alone")
	T.eq(one("[web](https://example.com/a_b_c#x) and <https://example.org>"), "[web](https://example.com/a_b_c#x) and https://example.org")
	T.eq(one("[pdf](papers/x.pdf)"), "[pdf](./papers/x.pdf)")
	T.eq(one('![alt](img/a.png "title") ![[pic.png|300]] ![[Sourdough]]'), "![./img/a.png] ![./attachments/pic.png] ![Sourdough]")
	T.eq(one("__bold__ and _italic_ but snake_case_name"), "**bold** and *italic* but snake_case_name")
	T.eq(one("#idea and #projects/home but not #123 or a#b"), "@idea and @projects-home but not #123 or a#b")
	T.eq(one("code `_x_ #tag [[Link]]` and $a_1 + b_2$ stay"), "code `_x_ #tag [[Link]]` and $a_1 + b_2$ stay")
	T.eq(one("costs $5 and _really_ $10"), "costs $5 and *really* $10")
end)

T.test("reference links resolve and their definitions go; stray [brackets] are reported", function()
	local out, warnings = MI.convert({
		"A [link][ref], a [collapsed][] one and a [shortcut].",
		"[WIP] not a link in Markdown",
		"",
		"[ref]: https://example.com/ref",
		"[collapsed]: https://example.com/c \"Title\"",
		"[shortcut]: ./notes.txt",
	}, { name = "Refs" })
	T.eq(out, {
		"@@Refs",
		"",
		"A [link](https://example.com/ref), a [collapsed](https://example.com/c) one and a [shortcut](./notes.txt).",
		"[WIP] not a link in Markdown",
	})
	T.eq(warnings, { { lnum = 4, text = "[WIP] reads as a link in a note" } })
end)

T.test("--join flows wrapped paragraphs, items and quotes; breaks and labels stay", function()
	local out = convert({
		"A paragraph that",
		"wraps over lines.",
		"",
		"- an item that",
		"  wraps too",
		"- next",
		"",
		"> a quote",
		"> that wraps",
		"",
		"Hard break  ",
		"next line",
		"Ingredients:",
		"flour",
	}, { name = "Wrap", join = true })
	T.eq(out, {
		"@@Wrap",
		"",
		"A paragraph that wraps over lines.",
		"",
		"- an item that wraps too",
		"- next",
		"",
		"> a quote that wraps",
		"",
		"Hard break",
		"next line Ingredients:",
		"flour",
	})
end)

T.test("a folder: notes next to the files, links between them, embeds found", function()
	local dir = vim.fn.tempname() .. "/vault"
	vim.fn.mkdir(dir .. "/sub", "p")
	vim.fn.mkdir(dir .. "/attachments", "p")
	vim.fn.mkdir(dir .. "/.obsidian", "p")
	vim.fn.writefile({ "---", "title: Home Page", "---", "", "Go to [[Garden]] or [[sub/Deep|deep notes]].", "![[pic.png]]" }, dir .. "/index.md")
	vim.fn.writefile({ "# Garden", "", "## Raised beds", "", "Back [home](index.md)." }, dir .. "/Garden.md")
	vim.fn.writefile({ "See [beds](../Garden.md#raised-beds)." }, dir .. "/sub/Deep.md")
	vim.fn.writefile({ "png" }, dir .. "/attachments/pic.png")
	vim.fn.writefile({ "# Hidden" }, dir .. "/.obsidian/x.md")
	vim.fn.writefile({ "@@Kept" }, dir .. "/sub/Deep.zortex")

	local res = MI.import(dir)
	table.sort(res.converted)
	T.eq(res.converted, { dir .. "/Garden.zortex", dir .. "/index.zortex" })
	T.eq(res.skipped, { dir .. "/sub/Deep.zortex" })
	T.eq(vim.fn.readfile(dir .. "/index.zortex"), {
		"@@Home Page",
		"",
		"Go to [Garden] or deep notes [Deep].",
		"![./attachments/pic.png]",
	})
	T.eq(vim.fn.readfile(dir .. "/Garden.zortex"), { "@@Garden", "", "## Raised beds", "", "Back home [Home Page]." })
	T.eq(vim.fn.readfile(dir .. "/sub/Deep.zortex"), { "@@Kept" }, "kept without force")
	res = MI.import(dir, { force = true })
	T.eq(vim.fn.readfile(dir .. "/sub/Deep.zortex"), { "@@Deep", "", "See beds [Garden/#Raised beds]." })
	T.eq(vim.fn.filereadable(dir .. "/.obsidian/x.zortex"), 0, "hidden folders are skipped")
	vim.fn.delete(vim.fn.fnamemodify(dir, ":h"), "rf")
end)
