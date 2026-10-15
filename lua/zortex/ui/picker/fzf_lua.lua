-- ui/picker/fzf_lua.lua - The picker interface (ui/picker) on fzf-lua
--
-- fzf-lua's own keys open: enter, ctrl-s split, ctrl-v vsplit, ctrl-t tab;
-- tab selects several; alt-q sends the selection to the quickfix list. Rows
-- are "<index>\t<display>" (fzf shows and matches the display); live lists
-- re-run on what you type and keep their own order. A key that re-lists
-- (sort, mode, ...) reopens the picker with the query kept.
local Picker = require("zortex.ui.picker")

local M = {}

-- "<C-l>" -> "ctrl-l", "<M-t>" -> "alt-t"
function M.fzf_key(lhs)
	local mod, key = lhs:match("^<([CMAcma])%-(.+)>$")
	if not mod then
		return lhs:lower()
	end
	return (mod:lower() == "c" and "ctrl-" or "alt-") .. key:lower()
end

local function ansi(hl, text)
	local ok, colored = pcall(require("fzf-lua.utils").ansi_from_hl, hl, text)
	return ok and colored or text
end

function M.pick(spec)
	local fzf = require("fzf-lua")
	local current = {}

	local function lines(list)
		current = list
		local out = {}
		for i, item in ipairs(list) do
			local parts = {}
			for _, seg in ipairs(spec.format(item)) do
				local text = (seg[1] or ""):gsub("[\t\n]", " ")
				if text ~= "" then
					parts[#parts + 1] = seg[2] and ansi(seg[2], text) or text
				end
			end
			out[i] = i .. "\t" .. table.concat(parts)
		end
		return out
	end

	local function item_of(entry)
		local i = type(entry) == "string" and tonumber(entry:match("^(%d+)\t"))
		return i and current[i] or nil
	end

	local function items_of(selected)
		local out = {}
		for _, entry in ipairs(selected or {}) do
			out[#out + 1] = item_of(entry)
		end
		return out
	end

	local Previewer
	if spec.preview then
		local base = require("fzf-lua.previewer.builtin").base
		Previewer = base:extend()
		function Previewer:new(o, opts)
			Previewer.super.new(self, o, opts)
			setmetatable(self, Previewer)
			return self
		end
		function Previewer:populate_preview_buf(entry)
			local item = item_of(entry)
			if not item then
				return
			end
			local buf = self:get_tmp_buffer()
			local p = Picker.fill_preview(spec, item, buf)
			self:set_preview_buf(buf)
			local win = self.win and self.win.preview_winid
			if p and p.lnum and win and vim.api.nvim_win_is_valid(win) then
				pcall(vim.api.nvim_win_set_cursor, win, { p.lnum, 0 })
				vim.api.nvim_win_call(win, function()
					vim.cmd("normal! zz")
				end)
			end
			if self.win and self.win.update_preview_title then
				pcall(self.win.update_preview_title, self.win, " " .. ((p and p.title) or "Preview") .. " ")
			end
		end
		function Previewer:gen_winopts()
			return vim.tbl_extend("force", self.winopts or {}, { wrap = false, number = false, cursorline = false })
		end
	end

	local function open(cmd)
		return function(selected)
			Picker.confirm(spec, items_of(selected), cmd)
		end
	end
	local actions = {
		["enter"] = open("edit"),
		["ctrl-s"] = open("split"),
		["ctrl-v"] = open("vsplit"),
		["ctrl-t"] = open("tabedit"),
		["alt-q"] = function(selected)
			local items = items_of(selected)
			if #items > 0 then
				Picker.quickfix(spec, items)
			end
		end,
	}
	for _, k in ipairs(Picker.keys(spec)) do
		local key = k.key
		local function run(selected, opts)
			local ctx = { prompt = opts and opts.last_query or "" }
			if key.refresh then
				ctx.refresh = function()
					spec.prompt = ctx.prompt
					vim.schedule(function()
						M.pick(spec)
					end)
				end
			end
			Picker.run_key(key, item_of((selected or {})[1]), ctx)
		end
		if key.close or key.refresh then
			actions[M.fzf_key(k.lhs)] = run
		else
			actions[M.fzf_key(k.lhs)] = { fn = run, exec_silent = true }
		end
	end

	local opts = {
		prompt = "> ",
		query = spec.prompt,
		winopts = { title = " " .. Picker.title(spec) .. " " },
		fzf_opts = {
			["--delimiter"] = "\t",
			["--with-nth"] = "2..",
			["--multi"] = true,
			["--ansi"] = true,
		},
		previewer = Previewer,
		actions = actions,
	}
	if spec.query then
		opts.exec_empty_query = true
		return fzf.fzf_live(function(args)
			local q = type(args) == "table" and args[1] or args
			return lines(spec.query(type(q) == "string" and q or ""))
		end, opts)
	end
	return fzf.fzf_exec(lines(spec.items()), opts)
end

return M
