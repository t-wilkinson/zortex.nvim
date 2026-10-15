-- tests/gen_links.lua - Regenerate the link resolution and search fixtures
--
--   nvim --headless -u NONE -l tests/gen_links.lua
--
-- Runs the Lua link resolver and structural search over a copy of
-- tests/fixtures/notes and writes what they return:
--
--   tests/fixtures/resolve.json  [{ link, from?, lnum?, results = [{ rel, lnum, col }], error? }]
--                                (lnum: the line a parent-relative [./-Item] link is written on)
--   tests/fixtures/search.json   [{ prompt, mode, results = [{ type, rel, lnum, breadcrumb?, score?, child? }] }]
--
-- The cases are every section of every note (its canonical link), every link
-- and tag search written in the notes, and the hand-picked cases below. The
-- Go port (app/links, app/search) is tested against these files; test_links.lua
-- checks that they are up to date.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local M = {}

M.RESOLVE = root .. "/tests/fixtures/resolve.json"
M.SEARCH = root .. "/tests/fixtures/search.json"

-- Hand-picked links: aliases, tags, namespaces, prefixes, case, items,
-- queries, archives, local links and failures.
M.EXTRA_LINKS = {
	{ link = "[Projects]" },
	{ link = "[P]" },
	{ link = "[p/#1.4 - ZORTEX]" },
	{ link = "[P/#1.4]" },
	{ link = "[P/#1.4 - zortex/#1.4.1]" },
	{ link = "[@P]" },
	{ link = "[@P/#Subaru]" },
	{ link = "[P/Flipping/#Subaru outback]" },
	{ link = "[P/#Subaru outback]" },
	{ link = "[Car maintenance/#Subaru]" },
	{ link = "[Me]" },
	{ link = "[@Me]" },
	{ link = "[@Cars]" },
	{ link = "[@Nope]" },
	{ link = "[Nope]" },
	{ link = "[P/#No such project]" },
	{ link = "[P/#1 Programming/#1.4 - zortex/-Improve website]" },
	{ link = "[P/#1.4 - zortex/-improve]" },
	{ link = "[P/-Weekly]" },
	{ link = "[O/#Current/#3M-2026-Q1 Establish/-KR2]" },
	{ link = "[O/#Current/#3M-2026-Q1 Ship zortex projects/-KR1]" },
	{ link = "[Calendar/:2026-10-06/-Call the mechanic]" },
	{ link = "[A/#1 Personal Foundation/#1.2 Vitality/:Fitness]" },
	{ link = "[A/:Fitness]" },
	{ link = "[Areas/#4 Learning]" },
	{ link = "[P/%website]" },
	{ link = "[P/%Website]" },
	{ link = "[%zortex]" },
	{ link = "[@Archive]" },
	{ link = "[@Archive/#1.4 - zortex]" },
	{ link = "[Projects/@Archive/#old]" },
	{ link = "[/#1.4 - zortex]", from = "projects.zortex" },
	{ link = "[/:Notes]", from = "projects.zortex" },
	{ link = "[/#Subaru]", from = "flipping.zortex" },
	{ link = "[/#nothing here]", from = "projects.zortex" },
	{ link = "[P/@size(lg)]" },
	{ link = "[R/>The Rust Book]" },
	{ link = "[R/#Rust/>rust]" },
	{ link = "[R/#Rust/>]" },
	{ link = "[R/#Rust/>Async]" },
	{ link = "[R/#Rust/>https:]" },
	{ link = "[R/#Rust/>Garden notes]" },
	{ link = "[R/#Rust/>Flipping]" },
	{ link = "[R/#Embedded/>pinout]" },
	{ link = "[R/#Embedded/>.]" },
	{ link = "[R/#AI/>Sutton & Barto]" },
	{ link = "[R/#AI/>lecture]" },
	{ link = "[R/#AI/>Reading]" },
	{ link = "[R/#AI/>nothing]" },
	{ link = "[R/>Spinning/#AI]" },
	{ link = "[>Spinning]" },
	{ link = "[/>The Rust]", from = "z/resources.zortex" },
	{ link = "[R/#Rust/-The Rust Book]" },
	{ link = "[R/-rust by]" },
	{ link = "@[R/rust]" },
	{ link = "@[R/#Rust/async]" },
	{ link = "@[R/embedded rust]" },
	{ link = "@[R/#Rust/embedded]" },
	{ link = "@[@Library/rl]" },
	{ link = "@[@Library/rl ai-model]" },
	{ link = "@[R/@rl @ai-model]" },
	{ link = "@[*/rl]" },
	{ link = "@[*/rust, rl]" },
	{ link = "@[R/#Rust/-The Rust Book/rust]" },
	{ link = "@[R/nothing]" },
	{ link = "@[R/book]" }, -- resource headings, not their notes
	{ link = "@[R/#Books/rust book]" },
	{ link = "@[R/#Later/book]" }, -- the item, not its notes
	{ link = "@[R/#Later/status]" },
	{ link = "@[Nope/rl]" },
	{ link = "@[R/#Rust/ , ]" },
	{ link = "@[rl]", from = "z/resources.zortex" },
	{ link = "@[/#AI/rl]", from = "z/resources.zortex" },
	{ link = "P/#1.4" },
	{ link = "[]" },
	-- parent-relative: on a line with no linked parent, and on deeper lines
	{ link = "[./-Item]", from = "z/day-plan.zortex", lnum = 1 },
	{ link = "[./-Fix project search]", from = "z/day-plan.zortex", lnum = 4 },
	{ link = "[./-Nothing like this]", from = "z/day-plan.zortex", lnum = 6 },
}

M.SEARCHES = {
	{ prompt = "" },
	{ prompt = "p" },
	{ prompt = "z" },
	{ prompt = "zortex" },
	{ prompt = "1.4 zortex" },
	{ prompt = "programming zortex" },
	{ prompt = "zortex programming" },
	{ prompt = "zortex search" },
	{ prompt = "proj zortex search" },
	{ prompt = "1 4" },
	{ prompt = "personal habits" },
	{ prompt = "#habits" },
	{ prompt = "#" },
	{ prompt = "@@proj" },
	{ prompt = "@@" },
	{ prompt = ":notes" },
	{ prompt = ":" },
	{ prompt = "*bold" },
	{ prompt = "subaru" },
	{ prompt = "car subaru" },
	{ prompt = "fitness" },
	{ prompt = "vitality fitness" },
	{ prompt = "kr" },
	{ prompt = "routine" },
	{ prompt = "1.4_-_zortex" },
	{ prompt = "1.4\\ -\\ zortex" },
	{ prompt = "a b c d" },
	{ prompt = "nothing-matches-this" },
	{ prompt = "P", mode = "article" },
	{ prompt = "o", mode = "article" },
	{ prompt = "", mode = "article" },
	-- file names are article aliases: okr.zortex is @@Objectives
	{ prompt = "okr" },
	{ prompt = "okr", mode = "article" },
	{ prompt = "day-plan", mode = "article" },
}

-- Pretty JSON with sorted keys (same as gen_ast.lua)
local function encode(value, indent)
	indent = indent or ""
	if type(value) == "table" then
		local n = #value
		local is_array = n > 0 or next(value) == nil
		if is_array then
			for k in pairs(value) do
				if type(k) ~= "number" then
					is_array = false
					break
				end
			end
		end
		local inner = indent .. "  "
		local parts = {}
		if is_array then
			if n == 0 then
				return "[]"
			end
			for i = 1, n do
				parts[#parts + 1] = inner .. encode(value[i], inner)
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
		end
		local keys = vim.tbl_keys(value)
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = inner .. vim.json.encode(tostring(k)) .. ": " .. encode(value[k], inner)
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	end
	return vim.json.encode(value)
end
M.encode = encode

--- Point Config at a throwaway copy of the fixture notes.
function M.use_fixture_copy()
	local Config = require("zortex.config")
	local dir = vim.fn.tempname() .. "/notes/"
	vim.fn.mkdir(dir, "p")
	vim.fn.system({ "cp", "-r", root .. "/tests/fixtures/notes/.", dir })
	Config.notes_dir = dir
	Config.extension = Config.extension or ".zortex"
	require("zortex.core.notes").invalidate()
	require("zortex.core.document").invalidate()
	return dir
end

--- The resolve cases and their results (needs Config.notes_dir set).
function M.resolve_cases()
	local Config = require("zortex.config")
	local notes = require("zortex.core.notes")
	local Document = require("zortex.core.document")
	local resolver = require("zortex.core.link")
	local syntax = require("zortex.core.syntax")
	local dir = Config.notes_dir
	local function rel(path)
		return path:sub(#dir + 1)
	end

	local cases, seen = {}, {}
	local function add(link, from, lnum)
		local key = link .. "\0" .. (from or "") .. "\0" .. (lnum or "")
		if not seen[key] then
			seen[key] = true
			cases[#cases + 1] = { link = link, from = from, lnum = lnum }
		end
	end

	for _, path in ipairs(notes.files({ include_archived = true })) do
		local doc = Document.get(path)
		-- every section's canonical link
		doc.tree:walk(function(node)
			if not node:is_root() then
				local link = resolver.link_for_node(doc, node)
				if link then
					add(link)
				end
			end
		end)
		-- every link written in the note (local links resolve in that note)
		for lnum, line in ipairs(doc.lines) do
			if not doc:in_code(lnum) then
				for _, span in ipairs(syntax.links(line)) do
					local def = span.definition
					if resolver.is_parent_relative(def) then
						add("[" .. def .. "]", rel(path), lnum)
					else
						add("[" .. def .. "]", def:sub(1, 1) == "/" and rel(path) or nil)
					end
				end
				-- tag searches (@[tags] searches the note it is in)
				syntax.walk_spans(syntax.inline(line), function(span)
					if span.type == "tag_search" then
						add("@[" .. span.content .. "]", rel(path))
					end
				end)
			end
		end
	end
	for _, c in ipairs(M.EXTRA_LINKS) do
		add(c.link, c.from, c.lnum)
	end

	for _, c in ipairs(cases) do
		local opts
		if c.from then
			opts = { doc = Document.get(dir .. c.from), lnum = c.lnum }
		end
		local results, err = resolver.resolve(c.link, opts)
		c.results = {}
		for _, r in ipairs(results) do
			c.results[#c.results + 1] = { rel = rel(r.file), lnum = r.lnum, col = r.col }
		end
		if #results == 0 then
			c.error = err
		end
	end
	return cases
end

--- The search cases and their results (needs Config.notes_dir set).
function M.search_cases()
	local Config = require("zortex.config")
	local search = require("zortex.services.search")
	search.setup()
	local dir = Config.notes_dir
	local index = search.build_index(search.files())
	local cases = {}
	for _, s in ipairs(M.SEARCHES) do
		local mode = s.mode or "section"
		local out = {}
		for _, r in ipairs(search.query_index(index, s.prompt, { mode = mode })) do
			if r.result_type == "section" then
				out[#out + 1] = {
					type = "section",
					rel = r.filepath:sub(#dir + 1),
					lnum = r.node.start_line,
					breadcrumb = r.breadcrumb,
					score = r.score,
					child = r.child or nil,
				}
			else
				out[#out + 1] = { type = "line", rel = r.filepath:sub(#dir + 1), lnum = r.lnum }
			end
		end
		cases[#cases + 1] = { prompt = s.prompt, mode = mode, results = out }
	end
	return cases
end

if not package.loaded["helpers"] then
	M.use_fixture_copy()
	vim.fn.writefile(vim.split(encode(M.resolve_cases()), "\n"), M.RESOLVE)
	vim.fn.writefile(vim.split(encode(M.search_cases()), "\n"), M.SEARCH)
	print("wrote " .. M.RESOLVE)
	print("wrote " .. M.SEARCH)
	os.exit(0)
end

return M
