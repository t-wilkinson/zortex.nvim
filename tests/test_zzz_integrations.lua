-- The pickers on telescope, snacks.picker and fzf-lua, and the blink.cmp
-- source, against the real plugins. Runs with ZORTEX_TEST_PLUGINS=dir (a
-- folder with telescope.nvim, plenary.nvim, snacks.nvim, fzf-lua, blink.cmp
-- and bin/fzf; CI clones pinned versions); skipped otherwise.
local T = require("helpers")
local Picker = require("zortex.ui.picker")
local Config = require("zortex.config")

if (os.getenv("ZORTEX_TEST_PLUGINS") or "") == "" then
	print("  skip (set ZORTEX_TEST_PLUGINS to run the plugin integration tests)")
	return
end

-- (changing 'lines' here crashes headless Neovim once snacks opens a picker)
vim.o.columns = 200
Config.ui = Config.ui or {}
require("zortex.features.highlights").setup()

local LIST_FT = { TelescopeResults = true, snacks_picker_list = true, fzf = true }

local function wins()
	return vim.api.nvim_tabpage_list_wins(0)
end

local function list_buf()
	for _, w in ipairs(wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if LIST_FT[vim.bo[b].filetype] then
			return b
		end
	end
end

local function rows()
	local b = list_buf()
	if not b then
		return {}
	end
	return vim.tbl_filter(function(l)
		return l:match("%S") ~= nil
	end, vim.api.nvim_buf_get_lines(b, 0, -1, false))
end

local function has_row(text)
	for _, r in ipairs(rows()) do
		if r:find(text, 1, true) then
			return true
		end
	end
	return false
end

-- Window titles: telescope draws them into its border buffers, snacks and
-- fzf-lua set them on the window
local function titles()
	local out = {}
	for _, w in ipairs(vim.tbl_filter(vim.api.nvim_win_is_valid, wins())) do
		local t = vim.api.nvim_win_get_config(w).title
		if type(t) == "table" then
			out[#out + 1] = table.concat(vim.tbl_map(function(c)
				return type(c) == "table" and c[1] or c
			end, t))
		elseif type(t) == "string" then
			out[#out + 1] = t
		end
		out[#out + 1] = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false))
	end
	return table.concat(out, "\n")
end

local TERM = { ["<CR>"] = "\r", ["<Tab>"] = "\t", ["<M-q>"] = "\27q", ["<C-q>"] = "\17" }

-- Type into the picker: keys to the prompt (telescope, snacks) or the fzf
-- terminal
local function send(backend, keys)
	if backend == "fzf_lua" then
		local b = list_buf()
		local chan = vim.bo[b].channel
		local ctrl = keys:match("^<C%-(%a)>$")
		local alt = keys:match("^<M%-(%a)>$")
		local data = TERM[keys] or (ctrl and string.char(ctrl:lower():byte() - 96)) or (alt and ("\27" .. alt)) or keys
		vim.api.nvim_chan_send(chan, data)
		return
	end
	-- the prompt buffer's mapping for the key, called as typing it would
	local prompt = vim.api.nvim_get_current_buf()
	local map = vim.api.nvim_buf_call(prompt, function()
		return vim.fn.maparg(keys, "i", false, true)
	end)
	assert(map.buffer == 1, backend .. ": no " .. keys .. " mapping in the prompt")
	if map.callback then
		map.callback()
	else
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), "m", false)
	end
end

local function closed()
	return list_buf() == nil
end

local function reset()
	for _, w in ipairs(wins()) do
		if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	vim.cmd("silent! only | enew!")
	vim.cmd("stopinsert")
	vim.fn.setqflist({}, "f")
	T.wait(300, function()
		return closed()
	end)
end

local QF_KEY = { telescope = "<C-q>", snacks = "<C-q>", fzf_lua = "<M-q>" }

local BACKENDS = {
	{ "telescope", "telescope.pickers" },
	{ "snacks", "snacks" },
	{ "fzf_lua", "fzf-lua" },
}

for _, b in ipairs(BACKENDS) do
	local name, mod = b[1], b[2]
	if not T.plugin(mod) then
		print("  skip " .. name .. " (" .. mod .. " not found)")
	else
		T.test(name .. ": live search lists results in order and <CR> opens the first", function()
			reset()
			local spec = require("zortex.ui.picker.search").spec({ mode = "section", prompt = "rust" })
			local first = spec.query("rust")[1]
			local loc = spec.location(first)
			Picker.pick(spec, { backend = name })
			T.ok(T.wait(5000, function()
				return has_row("Resources › Rust")
			end), "rows: " .. vim.inspect(rows()))
			T.ok(titles():find("Zortex Structural Search (section)", 1, true), titles())
			T.wait(500, function() end)
			send(name, "<CR>")
			T.ok(T.wait(3000, function()
				return closed() and vim.api.nvim_buf_get_name(0) == loc.file
			end), "opened " .. vim.api.nvim_buf_get_name(0))
			T.eq(vim.fn.line("."), loc.lnum)
		end)

		T.test(name .. ": a refresh key re-lists with a new title; <C-y> keeps the picker open", function()
			reset()
			local spec = require("zortex.ui.picker.projects").spec()
			Picker.pick(spec, { backend = name })
			T.ok(T.wait(5000, function()
				return has_row("zortex")
			end), "rows: " .. vim.inspect(rows()))
			T.ok(titles():find("Projects (score)", 1, true), titles())
			send(name, "<M-s>")
			T.ok(T.wait(5000, function()
				return titles():find("Projects (okr)", 1, true) and has_row("zortex")
			end), "title after <M-s>: " .. titles())
			vim.fn.setreg('"', "")
			send(name, "<C-y>")
			T.ok(T.wait(3000, function()
				return vim.fn.getreg('"'):match("^%[P/")
			end), "yanked: " .. vim.fn.getreg('"'))
			T.ok(not closed(), "picker stays open")
		end)

		T.test(name .. ": a closing key (<C-l>) runs on the row after the picker closes", function()
			reset()
			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "see " })
			vim.api.nvim_win_set_cursor(0, { 1, 3 })
			local spec = require("zortex.ui.picker.projects").spec()
			Picker.pick(spec, { backend = name })
			T.ok(T.wait(5000, function()
				return has_row("zortex")
			end))
			T.wait(300, function() end)
			send(name, "<C-l>")
			T.ok(T.wait(3000, function()
				return closed() and vim.api.nvim_get_current_line():match("^see %[P/")
			end), "line: " .. vim.api.nvim_get_current_line())
		end)

		T.test(name .. ": two selected rows go to the quickfix list", function()
			reset()
			local spec = require("zortex.ui.picker.calendar").spec()
			Picker.pick(spec, { backend = name })
			T.ok(T.wait(5000, function()
				return #rows() > 2 and has_row("2026")
			end), "rows: " .. vim.inspect(rows()))
			T.wait(300, function() end)
			send(name, "<Tab>")
			T.wait(200, function() end)
			send(name, "<Tab>")
			T.wait(200, function() end)
			send(name, QF_KEY[name])
			T.ok(T.wait(3000, function()
				return #vim.fn.getqflist() == 2
			end), "quickfix: " .. vim.inspect(vim.fn.getqflist()))
			local qf = vim.fn.getqflist({ title = 1 })
			T.eq(qf.title, "Calendar")
			T.ok(vim.api.nvim_buf_get_name(vim.fn.getqflist()[1].bufnr):match("calendar%.zortex$"))
		end)
	end
end

if T.plugin("blink.cmp") then
	T.test("blink.cmp: the zortex provider is added and listed in zortex buffers", function()
		reset()
		local blink = require("blink.cmp")
		blink.setup({ fuzzy = { implementation = "lua" } })
		local completion = require("zortex.features.completion")
		T.eq(completion.register(), "blink")
		completion.register() -- again: no duplicate provider error
		local config = require("blink.cmp.config")
		T.eq(config.sources.providers.zortex.module, "zortex.features.blink")
		vim.cmd("edit " .. vim.fn.fnameescape(T.fixture("calendar.zortex")))
		vim.bo.filetype = "zortex" -- (-u NONE: no filetype detection)
		local ids = require("blink.cmp.sources.lib").get_enabled_provider_ids("default")
		T.ok(vim.tbl_contains(ids, "zortex"), vim.inspect(ids))
		T.ok(vim.tbl_contains(ids, "buffer"), "keeps the default sources: " .. vim.inspect(ids))
	end)

	T.test("blink.cmp: the source completes link components with a text edit", function()
		local Source = require("zortex.features.blink")
		local src = Source.new({})
		T.ok(src:enabled())
		T.ok(vim.tbl_contains(src:get_trigger_characters(), "["))
		local line = "See [P/#1.4 - zor"
		local got
		src:get_completions({ line = line, cursor = { 3, #line }, bufnr = 0 }, function(r)
			got = r
		end)
		local item
		for _, i in ipairs(got.items) do
			if i.label == "#1.4 - zortex" then
				item = i
			end
		end
		T.ok(item, vim.inspect(vim.tbl_map(function(i)
			return i.label
		end, got.items)))
		T.eq(item.textEdit.range.start, { line = 2, character = 7 })
		T.eq(item.textEdit.range["end"], { line = 2, character = #line })
		-- applied (as blink does, UTF-8 columns), it replaces the component
		vim.api.nvim_buf_set_lines(0, 2, 3, false, { line })
		vim.lsp.util.apply_text_edits({ item.textEdit }, vim.api.nvim_get_current_buf(), "utf-8")
		T.eq(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1], "See [P/#1.4 - zortex")
		vim.cmd("silent! edit!")
	end)

	T.test("blink.cmp: '[./-' lists the parent line's items, filtered as one word", function()
		vim.cmd("enew!")
		vim.bo.filetype = "zortex"
		local line = "    - [ ] [./-Imp"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "2026-10-15:", "16:00 [P/#1 Programming/#1.4 - zortex]", line })
		local got
		require("zortex.features.blink").new({}):get_completions({ line = line, cursor = { 3, #line }, bufnr = 0 }, function(r)
			got = r
		end)
		local item
		for _, i in ipairs(got.items) do
			if i.label == "-Improve website" then
				item = i
			end
		end
		T.ok(item, vim.inspect(vim.tbl_map(function(i)
			return i.label
		end, got.items)))
		T.eq(item.textEdit.range.start, { line = 2, character = #"    - [ ] [./" })
		T.eq(item.filterText, "-Improve website")
		vim.cmd("enew!")
	end)

	T.test("blink.cmp: its provider asks the source for the line at the cursor", function()
		vim.cmd("enew!")
		vim.bo.filetype = "zortex"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See [Fli" })
		vim.wo.virtualedit = "onemore"
		vim.api.nvim_win_set_cursor(0, { 1, 8 })
		local provider = require("blink.cmp.sources.lib").get_provider_by_id("zortex")
		T.ok(provider:enabled())
		local context = require("blink.cmp.completion.trigger.context").new({
			id = 1,
			providers = { "zortex" },
			initial_trigger_kind = "trigger_character",
			initial_trigger_character = "[",
			trigger_kind = "keyword",
		})
		local labels
		provider:get_completions(context, function(items)
			labels = vim.tbl_map(function(i)
				return i.label
			end, items)
		end)
		T.ok(T.wait(3000, function()
			return labels
		end))
		T.ok(vim.tbl_contains(labels, "Flipping"), vim.inspect(labels))
		vim.wo.virtualedit = ""
	end)
else
	print("  skip blink.cmp (not found)")
end

reset()
