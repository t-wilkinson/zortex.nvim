-- ui/picker/init.lua - One picker interface over telescope, snacks.picker,
-- fzf-lua and vim.ui.select (ui.picker: "auto" or a backend name).
--
-- The zortex pickers (ui/picker/search, projects, follow, calendar) describe
-- what to list as a spec; a backend (ui/picker/<name>) shows it:
--
--   pick({
--     title  = "Projects" | fun(): string,  -- re-read on refresh
--     items  = fun(): item[],               -- a list the picker filters, or
--     query  = fun(prompt): item[],         -- a "live" list: re-run as you type, in its own order
--     text   = fun(item): string,           -- what fuzzy matching sees (items)
--     format = fun(item): { {text, hl?}, ... },
--     location = fun(item): { file, lnum, col?, text? },  -- quickfix and previews
--     preview  = fun(item): { lines, lnum?, range = {first, last}?, zortex = bool?, title? },
--     open     = fun(item, cmd),            -- cmd: "edit" | "split" | "vsplit" | "tabedit"
--     on_open  = fun(item),                 -- each item opened or sent to quickfix
--     keys = { ["<C-l>"] = { desc, fn = fun(item, ctx), close = bool, refresh = bool } },
--     prompt = "initial text",
--   })
--
-- Keys: <CR> opens; the backend's own split / vsplit / tab keys open there;
-- several selected items go to the quickfix list (the first one opens); the
-- backend's quickfix key sends the selection. `keys` are the same everywhere:
-- close = true closes the picker first; refresh = true re-lists after fn
-- (title and items). ctx: { prompt = the text typed, refresh = fun() }.
local M = {}

M.BACKENDS = { "telescope", "snacks", "fzf_lua", "select" }

local function has(mod)
	return (pcall(require, mod))
end

local function snacks_picker()
	local ok, snacks = pcall(require, "snacks")
	return ok and type(snacks) == "table" and snacks.picker ~= nil and snacks or nil
end

-- LazyVim's choice (vim.g.lazyvim_picker) names its backends differently
local LAZYVIM = { snacks = "snacks", fzf = "fzf_lua", telescope = "telescope" }

local function available(name)
	if name == "telescope" then
		return has("telescope.pickers")
	elseif name == "snacks" then
		return snacks_picker() ~= nil
	elseif name == "fzf_lua" then
		return has("fzf-lua")
	end
	return name == "select"
end

--- The backend `ui.picker` names, or for "auto": LazyVim's picker, then a
--- snacks.picker you enabled, telescope, fzf-lua, snacks.picker, and
--- vim.ui.select when none is installed.
---@return string
function M.backend()
	local want = (require("zortex.config").ui or {}).picker or "auto"
	if want ~= "auto" then
		if available(want) then
			return want
		end
		vim.notify_once(("zortex: ui.picker = %q is not installed; using vim.ui.select"):format(want), vim.log.levels.WARN)
		return "select"
	end
	local lazyvim = LAZYVIM[vim.g.lazyvim_picker or ""]
	if not lazyvim and vim.g.lazyvim_picker == "auto" then
		local ok, name = pcall(function()
			return _G.LazyVim.pick.picker.name
		end)
		lazyvim = ok and LAZYVIM[name or ""] or nil
	end
	if lazyvim and available(lazyvim) then
		return lazyvim
	end
	local snacks = snacks_picker()
	if snacks and vim.tbl_get(snacks, "config", "picker", "enabled") then
		return "snacks"
	end
	for _, name in ipairs({ "telescope", "fzf_lua", "snacks" }) do
		if available(name) then
			return name
		end
	end
	return "select"
end

-- =============================================================================
-- Shared behaviour (every backend calls these)
-- =============================================================================

function M.base_title(spec)
	return type(spec.title) == "function" and spec.title() or spec.title or "Zortex"
end

--- The title, then the zortex keys (their labels, zortex.keys) and the
--- backend's own help key: "Projects (score) · <C-l> link · … · <F1> help".
function M.title(spec, backend)
	local t = M.base_title(spec)
	backend = backend or M.backend()
	if backend == "select" then
		return t -- vim.ui.select has no keys of its own, nor ours
	end
	local hints = {}
	for lhs, k in pairs(spec.keys or {}) do
		if k.label then
			hints[#hints + 1] = lhs .. " " .. k.label
		end
	end
	table.sort(hints)
	local help = require("zortex.keys").PICKER_HELP[backend]
	if help then
		hints[#hints + 1] = help .. " help"
	end
	return #hints > 0 and (t .. " · " .. table.concat(hints, " · ")) or t
end

--- Display segments joined: text, and { {start, end_}, hl } byte ranges.
function M.render(spec, item)
	local text, hls = "", {}
	for _, seg in ipairs(spec.format(item)) do
		local s = seg[1] or ""
		if s ~= "" then
			local start = #text
			text = text .. s
			if seg[2] then
				hls[#hls + 1] = { { start, #text }, seg[2] }
			end
		end
	end
	return text, hls
end

function M.text(spec, item)
	return spec.text and spec.text(item) or (M.render(spec, item))
end

--- Send items to the quickfix list (and open it).
function M.quickfix(spec, items)
	local qf = {}
	for _, item in ipairs(items) do
		if spec.on_open then
			spec.on_open(item)
		end
		local loc = spec.location(item)
		qf[#qf + 1] = { filename = loc.file, lnum = loc.lnum or 1, col = loc.col or 1, text = loc.text or M.text(spec, item) }
	end
	vim.fn.setqflist({}, " ", { title = M.base_title(spec), items = qf })
	vim.cmd("copen")
end

--- <CR> and the split keys: one item opens; several go to the quickfix list
--- and the first opens.
function M.confirm(spec, items, cmd)
	items = vim.tbl_filter(function(i)
		return i ~= nil
	end, items or {})
	if #items == 0 then
		return
	end
	cmd = cmd or "edit"
	if #items > 1 then
		M.quickfix(spec, items)
		vim.cmd("wincmd p")
	elseif spec.on_open then
		spec.on_open(items[1])
	end
	spec.open(items[1], cmd)
end

--- Open a location: the default `open` for specs whose items are places.
function M.open_location(loc, cmd)
	vim.cmd((cmd or "edit") .. " " .. vim.fn.fnameescape(loc.file))
	pcall(vim.api.nvim_win_set_cursor, 0, { loc.lnum or 1, math.max((loc.col or 1) - 1, 0) })
	vim.cmd("normal! zz")
end

local preview_ns = vim.api.nvim_create_namespace("zortex_picker_preview")

--- Fill a preview buffer (and its window, when given) from spec.preview.
function M.fill_preview(spec, item, buf, win)
	if not (spec.preview and item and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local p = spec.preview(item)
	if not p then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, p.lines or {})
	vim.api.nvim_buf_clear_namespace(buf, preview_ns, 0, -1)
	if p.zortex then
		pcall(require("zortex.features.highlights").highlight_buffer, buf)
	end
	local count = vim.api.nvim_buf_line_count(buf)
	if p.range then
		for l = p.range[1], math.min(p.range[2], count) do
			vim.api.nvim_buf_set_extmark(buf, preview_ns, l - 1, 0, { line_hl_group = "Visual", priority = 150 })
		end
	end
	if p.lnum and p.lnum <= count then
		vim.api.nvim_buf_set_extmark(buf, preview_ns, p.lnum - 1, 0, { line_hl_group = "CursorLine", priority = 160 })
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_cursor, win, { p.lnum, 0 })
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! zz")
			end)
		end
	end
	return p
end

--- Insert-mode-friendly key list: { lhs, key } sorted by lhs.
function M.keys(spec)
	local out = {}
	for lhs, key in pairs(spec.keys or {}) do
		out[#out + 1] = { lhs = lhs, key = key }
	end
	table.sort(out, function(a, b)
		return a.lhs < b.lhs
	end)
	return out
end

--- Run a spec key: ctx = { prompt, refresh }.
function M.run_key(key, item, ctx)
	key.fn(item, ctx)
	if key.refresh and ctx.refresh then
		ctx.refresh()
	end
end

---@param spec table see the top of this file
---@param opts? { backend?: string }
function M.pick(spec, opts)
	local backend = (opts and opts.backend) or M.backend()
	spec.open = spec.open or function(item, cmd)
		M.open_location(spec.location(item), cmd)
	end
	return require("zortex.ui.picker." .. backend).pick(spec)
end

return M
