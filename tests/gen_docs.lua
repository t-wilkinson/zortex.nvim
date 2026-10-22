-- tests/gen_docs.lua - Regenerate the docs built from the code
--
--   nvim --headless -u NONE -l tests/gen_docs.lua
--
-- README.md: the table between <!-- actions:start --> and <!-- actions:end -->,
-- from zortex.actions. doc/zortex.txt (:help zortex): the whole file, from
-- zortex.actions and the defaults in lua/zortex/config.lua. test_zr_actions
-- fails when either is out of date.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local M = {}
M.readme = root .. "/README.md"
M.vimdoc = root .. "/doc/zortex.txt"
M.START, M.STOP = "<!-- actions:start -->", "<!-- actions:end -->"

--- Markdown for every action, grouped, with the default prefixes.
function M.actions_markdown()
	local actions = require("zortex.actions")
	local out, group = {}, nil
	for _, a in ipairs(actions.list) do
		if a.group ~= group then
			group = a.group
			if #out > 0 then
				out[#out + 1] = ""
			end
			out[#out + 1] = "**" .. group .. "**"
			out[#out + 1] = ""
			out[#out + 1] = "| Command | Keys | Action id | Does |"
			out[#out + 1] = "|---|---|---|---|"
		end
		local keys = type(a.key) == "table" and a.key or { a.key }
		local key_cells = vim.tbl_map(function(k)
			return "`<leader>z" .. k .. "`"
		end, keys)
		out[#out + 1] = string.format(
			"| %s | %s | `%s` | %s |",
			a.command and ("`:Zortex" .. a.command .. (a.nargs and a.nargs ~= 0 and " …" or "") .. "`") or "",
			table.concat(key_cells, " "),
			a.id,
			(a.desc:gsub("|", "\\|"))
		)
	end
	return out
end

M.KEYS_START, M.KEYS_STOP = "<!-- keys:start -->", "<!-- keys:end -->"

-- The keys of zortex's buffers and pickers (zortex.keys), with the defaults
local function key_rows(id)
	local rows, by = {}, {}
	for _, k in ipairs(require("zortex.keys").of(id, true)) do
		local r = by[k.action]
		if r then
			r[1] = r[1] .. " `" .. k.lhs .. "`"
		else
			r = { "`" .. k.lhs .. "`", k.desc }
			by[k.action] = r
			rows[#rows + 1] = r
		end
	end
	return rows
end

--- Markdown for the keys of zortex's buffers and pickers.
function M.keys_markdown()
	local keys = require("zortex.keys")
	local out = {}
	local function block(def, note)
		out[#out + 1] = ""
		out[#out + 1] = string.format("**%s** (%s)%s", def.name, def.where:match("^:") and ("`" .. def.where .. "`") or def.where, note or "")
		out[#out + 1] = ""
		out[#out + 1] = "| Key | Does |"
		out[#out + 1] = "|---|---|"
		for _, r in ipairs(key_rows(def.id)) do
			out[#out + 1] = string.format("| %s | %s |", r[1]:gsub("|", "\\|"), (r[2]:gsub("|", "\\|")))
		end
	end
	out[#out + 1] = "In zortex's own buffers `?` lists these keys; the pickers name theirs in"
	out[#out + 1] = "the title, with the picker's own help key: " .. keys.PICKER_HELP_TEXT .. "."
	for _, def in ipairs(keys.BUFFERS) do
		block(def, def.config and (" · keys in `" .. def.config .. "`") or nil)
	end
	for _, def in ipairs(keys.PICKERS) do
		block(def, (def.config and (" · keys in `" .. def.config .. "`") or "") .. " · picker")
	end
	return out
end

--- The README with the generated blocks replaced.
function M.render_readme(lines)
	local out, skipping = {}, false
	for _, line in ipairs(lines) do
		if line == M.START or line == M.KEYS_START then
			out[#out + 1] = line
			vim.list_extend(out, line == M.START and M.actions_markdown() or M.keys_markdown())
			skipping = true
		elseif line == M.STOP or line == M.KEYS_STOP then
			skipping = false
			out[#out + 1] = line
		elseif not skipping then
			out[#out + 1] = line
		end
	end
	return out
end

-- =============================================================================
-- doc/zortex.txt
-- =============================================================================

local W = 78

-- "text" ... "*tag*" right-aligned on one line
local function heading(title, tag)
	local t = "*" .. tag .. "*"
	return title .. string.rep(" ", math.max(1, W - #title - #t)) .. t
end

local function rule()
	return string.rep("=", W)
end

local function wrap(text, indent)
	indent = indent or ""
	local out, line = {}, indent
	for word in text:gmatch("%S+") do
		if #line + #word + 1 > W and line ~= indent then
			out[#out + 1] = line
			line = indent .. word
		else
			line = line == indent and (indent .. word) or (line .. " " .. word)
		end
	end
	if line ~= indent then
		out[#out + 1] = line
	end
	return out
end

local INTRO = {
	"zortex.nvim is a plain-text life-management system: notes are `.zortex`",
	"files (a markdown dialect) that link to each other by structure,",
	"`[Sourdough/#Method]` or `[P/#1.1 Kitchen shelves]`. Projects, areas,",
	"objectives and the calendar are notes too. Notes live in `notes_dir`",
	"(default `~/zortex`); `z/` holds resources and archives. The server",
	"(`zortex serve`) shows them in a browser and runs the calendar's",
	"notifications and the pomodoro (|zortex-server|).",
	"",
	"Requires Neovim 0.10 or newer. Optional: snacks.nvim, telescope.nvim or",
	"fzf-lua (pickers; `ui.picker`), blink.cmp or nvim-cmp (link completion).",
	"|:checkhealth| zortex checks the setup.",
	"",
	"The full documentation is in the repository:",
	"    README.md          quickstart, features",
	"    doc/Syntax.md      the note format (checked against the parser)",
	"    doc/Server.md      running the server",
	"    doc/Projects.md    projects and areas",
	"    doc/Planning.md    areas, OKRs, reviews, XP (Mastery, seasons)",
}

local SETUP = {
	"With lazy.nvim: >lua",
	"    { \"t-wilkinson/zortex.nvim\", config = function()",
	"        require(\"zortex\").setup({ notes_dir = \"~/zortex\" })",
	"    end }",
	"<",
	"Options go to setup(): >lua",
	"    require(\"zortex\").setup({",
	"      notes_dir = \"~/zortex\",",
	"      keymaps = { prefix = \"<leader>z\" },",
	"    })",
	"<",
	"setup() writes nothing. When key notes are missing (calendar, projects,",
	"areas, okr, structure, inbox) it says so once; `:Zortex init` creates the",
	"missing ones from short templates (|:Zortex|).",
	"",
	"Notes open folded to their headings (`features.folding.level`): |zR| opens",
	"every fold. A section marked `@fold` starts closed whenever the note is",
	"shown, whatever its level.",
}

local NOTES = {
	"A note starts with a header: `@@Name` lines (the first is the article name,",
	"the rest aliases) and `@Tag` lines. The body has headings (`#`..`######`),",
	"bold headings (`**Next steps:**`), labels (`Ideas:`), list items and tasks",
	"(`- [ ] task @size(sm)`, `14:00 event`), attributes (`@p1`,",
	"`@due(2026-10-20)`, `@area(4.1)`, `@spent(1h25m)`; short forms: `@a(4.1)`,",
	"`@n(15)` for `@notify(15)`, `@sm`, `@90m` for `@dur(90m)`) and links. A",
	"link's components narrow left to right: an article (or tag namespace like",
	"`P`), then `#heading`, `:label`, `*bold`, `-item` or `%text`, each matched",
	"by prefix, case-insensitively.",
	"",
	"Special notes: projects.zortex (`@@P`; any note tagged `@P` is a project",
	"too), areas.zortex (`@@A`), okr.zortex (`## 3M-2026-Q1 Title` objectives,",
	"grouped under top-level headings, with `- KR1: [ ]` key results),",
	"calendar.zortex (`YYYY-MM-DD:` days), structure.zortex (links to",
	"everything), inbox.zortex.",
}

local API = {
	"`require(\"zortex\")` is the API; services load on first use: >lua",
	"    local z = require(\"zortex\")",
	"    z.actions.review()                -- any action by id",
	"    z.run(\"review\", { args = \"14\" })  -- with command-style arguments",
	"    z.query.search(\"1.4 zortex\")      -- plain data, JSON-safe",
	"    z.projects.resolve(\"[P/#1.4 - zortex]\"):rollup()",
	"    z.links.resolve_first(\"[A/#1 Personal]\")",
	"<",
	"See README.md (Lua API) for the full list.",
}

local SERVER = {
	"`zortex serve` (Go, one binary) reads the notes folder: rendered notes,",
	"search, backlinks, the calendar's notifications (through ntfy), the",
	"pomodoro, timers, alarms, a stopwatch and time tracking (`@spent`). The",
	"plugin expects it running, locally or elsewhere: notifications, the",
	"pomodoro and the alerts Neovim shows come from it. Its address: >lua",
	"    require(\"zortex\").setup({",
	"      server = { api_endpoint = \"https://zortex.example.com\", api_key = \"…\" },",
	"    })",
	"<",
	"`server = { enabled = false }` leaves it out; the notes, links, projects,",
	"planning and XP work without it.",
	"doc/Server.md in the repository covers Docker, NixOS, a proxy with a login",
	"and ntfy.",
}

--- The defaults table of lua/zortex/config.lua, verbatim (tabs as 2 spaces).
function M.config_defaults()
	local lines = vim.fn.readfile(root .. "/lua/zortex/config.lua")
	local out, on = {}, false
	for _, l in ipairs(lines) do
		if l:match("^local defaults = {") then
			on = true
			out[#out + 1] = "{"
		elseif on and l == "}" then
			out[#out + 1] = "}"
			break
		elseif on then
			out[#out + 1] = (l:gsub("\t", "  "))
		end
	end
	return out
end

--- doc/zortex.txt
function M.vimdoc_lines()
	local out = {}
	local function add(t)
		if type(t) == "table" then
			vim.list_extend(out, t)
		else
			out[#out + 1] = t
		end
	end
	add("*zortex.txt*  Plain-text notes and life management for Neovim")
	add(string.rep(" ", W - #"*zortex* *zortex.nvim*") .. "*zortex* *zortex.nvim*")
	add("")
	add("Generated from lua/zortex/actions.lua and config.lua by tests/gen_docs.lua.")
	add("")
	add(rule())
	add(heading("CONTENTS", "zortex-contents"))
	add("")
	local sections = {
		{ "Introduction", "zortex-intro" },
		{ "Setup", "zortex-setup" },
		{ "Notes", "zortex-notes" },
		{ "Commands and keys", "zortex-commands" },
		{ "Configuration", "zortex-config" },
		{ "Lua API", "zortex-api" },
		{ "Server", "zortex-server" },
	}
	for i, sec in ipairs(sections) do
		local left = string.format("  %d. %s ", i, sec[1])
		local right = " |" .. sec[2] .. "|"
		add(left .. string.rep(".", W - #left - #right) .. right)
	end
	local function section(i, body)
		add("")
		add(rule())
		add(heading(string.format("%d. %s", i, sections[i][1]:upper()), sections[i][2]))
		add("")
		add(body)
	end
	section(1, INTRO)
	section(2, SETUP)
	section(3, NOTES)

	-- commands and keys
	local actions = require("zortex.actions")
	local cmds = {
		"Every action is a command (`:Zortex...`), a key after `keymaps.prefix`",
		"(default <leader>z) and `require(\"zortex\").actions.<id>()`. Change a key with",
		"`keymaps.mappings`: >lua",
		"    keymaps = { mappings = { task_toggle = \"t\", search_articles = false } }",
		"<",
		"`:Zortex` (or `:Zortex help`) lists them with your prefixes.",
	}
	local group
	for _, a in ipairs(actions.list) do
		if a.group ~= group then
			group = a.group
			cmds[#cmds + 1] = ""
			cmds[#cmds + 1] = group:upper() .. " ~"
		end
		local name = a.command and (":Zortex" .. a.command) or ("actions." .. a.id)
		local tag = a.command and ("*:Zortex" .. a.command .. "*") or ("*zortex-action-" .. a.id .. "*")
		cmds[#cmds + 1] = ""
		cmds[#cmds + 1] = name .. string.rep(" ", math.max(1, W - #name - #tag)) .. tag
		local keys = type(a.key) == "table" and a.key or { a.key }
		local key_text = #keys > 0 and table.concat(vim.tbl_map(function(k)
			return "<leader>z" .. k
		end, keys), " ") or nil
		local desc = a.desc:gsub("`", "")
		if not desc:match("[.!?)]$") or desc:match("%)$") then
			desc = desc .. "."
		end
		vim.list_extend(cmds, wrap(desc .. (key_text and (" Keys: " .. key_text .. ".") or "") .. " Id: " .. a.id .. ".", "    "))
	end

	-- the keys of zortex's own buffers and pickers (zortex.keys)
	local keys = require("zortex.keys")
	cmds[#cmds + 1] = ""
	local kt = "*zortex-keys*"
	cmds[#cmds + 1] = "KEYS IN ZORTEX BUFFERS AND PICKERS" .. string.rep(" ", W - 34 - #kt) .. kt
	cmds[#cmds + 1] = ""
	vim.list_extend(cmds, wrap("In these buffers `?` lists their keys; the pickers name theirs in the title, with the picker's own help key: " .. keys.PICKER_HELP_TEXT:gsub("`", "") .. ".", ""))
	local function kblock(def, picker)
		cmds[#cmds + 1] = ""
		local where = def.where .. (def.config and (", keys in " .. def.config) or "") .. (picker and ", picker" or "")
		cmds[#cmds + 1] = def.name:upper() .. " (" .. where .. ") ~"
		local width = 0
		local rows = key_rows(def.id)
		for _, r in ipairs(rows) do
			r[1] = r[1]:gsub("`", "")
			width = math.max(width, #r[1])
		end
		for _, r in ipairs(rows) do
			cmds[#cmds + 1] = "  " .. r[1] .. string.rep(" ", width - #r[1] + 2) .. r[2]
		end
	end
	for _, def in ipairs(keys.BUFFERS) do
		kblock(def)
	end
	for _, def in ipairs(keys.PICKERS) do
		kblock(def, true)
	end
	section(4, cmds)

	local config = {
		"setup() merges your options over these defaults: >lua",
	}
	for _, l in ipairs(M.config_defaults()) do
		config[#config + 1] = l == "" and "" or ("    " .. l)
	end
	config[#config + 1] = "<"
	section(5, config)
	section(6, API)
	section(7, SERVER)
	add("")
	add(" vim:tw=78:ts=8:ft=help:norl:")
	return out
end

if not package.loaded["helpers"] then
	vim.fn.writefile(M.render_readme(vim.fn.readfile(M.readme)), M.readme)
	print("updated " .. M.readme)
	vim.fn.writefile(M.vimdoc_lines(), M.vimdoc)
	print("updated " .. M.vimdoc)
	os.exit(0)
end

return M
