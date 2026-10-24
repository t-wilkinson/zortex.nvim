-- features/conflicts.lua - Sync conflict copies of notes, merged in a diff
--
-- When two devices change a note before they sync, Syncthing keeps both:
-- the note, and "note.sync-conflict-20261024-101500-ABCDEFG.zortex" beside
-- it (Dropbox and Nextcloud: "note (… conflicted copy …).zortex"). The copy
-- is left out of the notes (utils/filesystem.is_conflict_copy), so whatever
-- only it holds is lost until it is merged.
--
--   :ZortexConflicts          list the copies; pick one to open it in a diff
--                             beside its note, in a new tab (one copy: opens
--                             it straight away)
--   :ZortexConflicts done     in that tab: save the note, delete the copy
--                             (after asking), close the tab, and open the
--                             next copy if there is one
--
-- In the diff, `dp` on the copy's side puts a change into the note, `do` on
-- the note's side takes one from the copy; `]c` / `[c` move between changes
-- (Neovim's own diff keys). Only the note is ever saved.
-- setup() says how many copies there are when Neovim starts.
local M = {}

local function fs()
	return require("zortex.utils.filesystem")
end

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

--- The note a conflict copy belongs to (its path with the sync tool's
--- marker taken out), and what the marker says: { device?, time? }.
function M.original(path)
	local dir, name = path:match("^(.*/)([^/]+)$")
	dir, name = dir or "", name or path
	local stamp, device = name:match("%.sync%-conflict%-(%d+%-%d+)%-(%w+)")
	local base = name:gsub("%.sync%-conflict%-%d+%-%d+%-%w+", "", 1)
	if base == name then
		base = name:gsub("%s*%([^()]*conflicted copy[^()]*%)", "", 1)
	end
	local info = { device = device }
	if stamp then
		local y, mo, d, h, mi = stamp:match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)")
		if y then
			info.time = string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
		end
	end
	return dir .. base, info
end

--- Every conflict copy of a note under notes_dir: { { copy, original,
--- device?, time?, rel } }, sorted by path.
function M.list()
	local root = require("zortex.config").notes_dir or ""
	local out = {}
	for _, copy in ipairs(fs().find_all_notes(nil, { conflicts = true })) do
		local original, info = M.original(copy)
		out[#out + 1] = {
			copy = copy,
			original = original,
			device = info.device,
			time = info.time,
			rel = copy:sub(#root + 1),
		}
	end
	table.sort(out, function(a, b)
		return a.copy < b.copy
	end)
	return out
end

local function describe(c)
	local parts = {}
	if c.device then
		parts[#parts + 1] = "from " .. c.device
	end
	if c.time then
		parts[#parts + 1] = c.time
	end
	return #parts > 0 and table.concat(parts, ", ") or "conflict copy"
end

-- The copy being merged in this tab, or nil
local function current()
	local ok, c = pcall(function()
		return vim.t.zortex_conflict
	end)
	return ok and c or nil
end

--- Open conflict `c` (M.list) in a new tab: its note on the left, the copy
--- on the right, in diff mode. Returns the two windows.
function M.open(c)
	local root = require("zortex.config").notes_dir or ""
	vim.cmd("tabedit " .. vim.fn.fnameescape(c.original))
	local note_win = vim.api.nvim_get_current_win()
	if not fs().file_exists(c.original) then
		notify("Its note " .. c.original:sub(#root + 1) .. " is gone: write it to keep the copy's text", vim.log.levels.WARN)
	end
	vim.cmd("vertical rightbelow diffsplit " .. vim.fn.fnameescape(c.copy))
	local copy_win = vim.api.nvim_get_current_win()
	local copy_buf = vim.api.nvim_win_get_buf(copy_win)
	vim.bo[copy_buf].bufhidden = "wipe"
	vim.t.zortex_conflict = { copy = c.copy, original = c.original }
	local function bar(text)
		return "%#WinBar#" .. text:gsub("%%", "%%%%")
	end
	vim.wo[note_win].winbar = bar("Note " .. c.original:sub(#root + 1) .. "  ·  do: take a change  ·  :ZortexConflicts done")
	vim.wo[copy_win].winbar = bar("Copy " .. describe(c) .. "  ·  dp: put a change in the note")
	vim.api.nvim_set_current_win(note_win)
	vim.cmd("normal! gg]c")
	return note_win, copy_win
end

--- In a conflict tab: save the note, delete the copy (asks first unless
--- opts.force), close the tab, open the next copy. Returns true when the copy
--- was deleted.
function M.done(opts)
	local c = current()
	if not c then
		return notify("Not in a conflict diff (:ZortexConflicts opens one)", vim.log.levels.WARN)
	end
	local note_buf = vim.fn.bufnr(c.original)
	if note_buf > 0 and vim.bo[note_buf].modified then
		vim.api.nvim_buf_call(note_buf, function()
			vim.cmd("silent write")
		end)
	end
	local name = vim.fn.fnamemodify(c.copy, ":t")
	if not (opts and opts.force) then
		local answer = vim.fn.confirm("Delete the conflict copy " .. name .. "?", "&Delete\n&Keep it", 2)
		if answer ~= 1 then
			return false
		end
	end
	local copy_buf = vim.fn.bufnr(c.copy)
	if copy_buf > 0 then
		pcall(vim.api.nvim_buf_delete, copy_buf, { force = true })
	end
	if vim.fn.delete(c.copy) ~= 0 then
		notify("Couldn't delete " .. c.copy, vim.log.levels.ERROR)
		return false
	end
	vim.t.zortex_conflict = nil
	if #vim.api.nvim_list_tabpages() > 1 then
		vim.cmd("tabclose")
	else
		vim.cmd("diffoff!")
	end
	local rest = M.list()
	if #rest > 0 then
		notify(string.format("Deleted %s; %d more", name, #rest))
		M.open(rest[1])
	else
		notify("Deleted " .. name .. "; no conflicts left")
	end
	return true
end

--- :ZortexConflicts [done]
function M.command(args)
	local sub = vim.trim(args and args.args or "")
	if sub == "done" then
		return M.done()
	elseif sub ~= "" then
		return notify("Unknown: " .. sub .. " (done)", vim.log.levels.WARN)
	end
	local list = M.list()
	if #list == 0 then
		return notify("No sync conflict copies")
	elseif #list == 1 then
		return M.open(list[1])
	end
	require("zortex.ui.picker").pick({
		title = string.format("Sync conflicts (%d)", #list),
		items = function()
			return list
		end,
		text = function(c)
			return c.rel
		end,
		format = function(c)
			return { { c.rel }, { "  " .. describe(c), "Comment" } }
		end,
		location = function(c)
			return { file = c.copy, lnum = 1 }
		end,
		open = function(c)
			M.open(c)
		end,
	})
end

--- On startup: say how many copies there are.
function M.setup()
	vim.defer_fn(function()
		local ok, list = pcall(M.list)
		if ok and #list > 0 then
			notify(string.format("%d sync conflict cop%s: :ZortexConflicts merges them", #list, #list == 1 and "y" or "ies"), vim.log.levels.WARN)
		end
	end, 500)
end

return M
