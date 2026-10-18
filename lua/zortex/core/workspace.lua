-- core/workspace.lua - Editing notes
--
-- Reads go through core/document (cached snapshots that prefer a modified
-- buffer over the file). Writes go through this module:
--
--   * if the note is loaded in a buffer, the buffer is edited (you save it as
--     usual, undo works, other plugins see the change)
--   * otherwise the file on disk is edited directly
--
-- Notes also change underneath Neovim (the web app with -writable, a phone
-- through Syncthing). So before an edit the lines around it are compared
-- with the snapshot the caller read them from (Document.cached): when they
-- differ the edit is refused ("changed since it was read") instead of
-- landing on the wrong line. An unmodified buffer is reloaded first
-- (:checktime) if its file changed.
--
-- Edits that reach several notes (rename, move, inbox triage) run in a
-- batch (M.batch): notes that aren't open are loaded into hidden buffers,
-- edited there and saved, so M.undo_last() (:ZortexUndo) can take the whole
-- batch back in every note.
--
-- Every edit emits "workspace:lines_changed" { file, start_line, end_line, count }.
local M = {}

local Document = require("zortex.core.document")
local Events = require("zortex.core.event_bus")
local fs = require("zortex.utils.filesystem")

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

-- Resolve a target (bufnr or path) to (bufnr|nil, path).
local function resolve_target(target)
	if type(target) == "number" then
		local bufnr = target == 0 and vim.api.nvim_get_current_buf() or target
		local name = vim.api.nvim_buf_get_name(bufnr)
		return bufnr, name ~= "" and normalize(name) or nil
	end
	local path = normalize(target)
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		return bufnr, path
	end
	return nil, path
end

--- Current lines of a note (buffer if loaded, else the file).
function M.get_lines(target)
	local bufnr, path = resolve_target(target)
	if bufnr then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end
	-- through the document cache, so the next edit is checked against what
	-- the caller read here
	local doc = path and Document.get(path)
	return doc and vim.list_slice(doc.lines) or {}
end

--- Snapshot of a note (see core/document).
function M.document(target)
	local bufnr, path = resolve_target(target)
	if bufnr then
		return Document.from_buffer(bufnr)
	end
	return path and Document.get(path) or nil
end

-- The lines an edit of start_line..end_line depends on: those it replaces,
-- and the line above (an insert goes after it).
local function guarded(start_line, end_line)
	return math.max(1, start_line - 1), math.max(end_line, start_line)
end

-- nil when `now` agrees with `base` (the snapshot the caller read) around
-- the edit, else why not.
local function conflict(base, now, start_line, end_line, name)
	if not base then
		return nil
	end
	local a, b = guarded(start_line, end_line)
	for i = a, b do
		if base[i] ~= now[i] then
			return string.format(
				"%s changed since it was read (line %d); nothing written, try again",
				vim.fn.fnamemodify(name or "the note", ":t"),
				i
			)
		end
	end
	return nil
end

--- Replace lines start_line..end_line (1-based, inclusive) with `lines`.
--- Use end_line = start_line - 1 to insert before start_line.
--- The edit is refused when the note changed around it since the caller
--- read it (see the top of this file).
---@return boolean ok, string? err
function M.set_lines(target, start_line, end_line, lines)
	if type(lines) == "string" then
		lines = { lines }
	end
	local bufnr, path = resolve_target(target)

	if bufnr then
		-- an unmodified buffer whose file changed on disk is reloaded first;
		-- if that happened, the caller's line numbers may be off
		if not vim.bo[bufnr].modified and path and vim.fn.filereadable(path) == 1 then
			local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local tick = vim.api.nvim_buf_get_changedtick(bufnr)
			pcall(vim.cmd, "silent! checktime " .. bufnr)
			if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
				local err = conflict(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), start_line, end_line, path)
				if err then
					return false, err
				end
			end
		end
		vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, lines)
	else
		if not path then
			return false, "No file for target"
		end
		local current = fs.read_lines(path) or {}
		local base = Document.cached(path)
		local err = conflict(base and base.lines, current, start_line, end_line, path)
		if err then
			return false, err
		end
		local out = {}
		for i = 1, start_line - 1 do
			out[#out + 1] = current[i]
		end
		vim.list_extend(out, lines)
		for i = end_line + 1, #current do
			out[#out + 1] = current[i]
		end
		if not fs.write_lines(path, out) then
			return false, "Failed to write " .. path
		end
		Document.invalidate(path)
	end

	Events.emit("workspace:lines_changed", {
		file = path,
		start_line = start_line,
		end_line = end_line,
		count = #lines,
	})
	return true
end

function M.set_line(target, lnum, text)
	return M.set_lines(target, lnum, lnum, { text })
end

--- Insert lines before `lnum` (lnum = #lines + 1 appends).
function M.insert_lines(target, lnum, lines)
	return M.set_lines(target, lnum, lnum - 1, lines)
end

function M.delete_lines(target, start_line, end_line)
	return M.set_lines(target, start_line, end_line or start_line, {})
end

--- Create a note with `lines` if it doesn't exist yet. Returns its path.
function M.ensure_file(path, lines)
	path = normalize(path)
	if not fs.file_exists(path) then
		fs.write_lines(path, lines or {})
		Document.invalidate(path)
	end
	return path
end

-- =============================================================================
-- Batches: edits across notes, undone together
-- =============================================================================

local last -- { label, notes = { { bufnr, seq, save } ... } }

-- The undo state a buffer is at (undotree() of that buffer), after closing
-- the current undo block so the batch's edits start a new one
local function seq_of(bufnr)
	return vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("let &l:undolevels = &l:undolevels")
		return vim.fn.undotree().seq_cur
	end)
end

--- Run `fn` with every note in `files` loaded in a buffer: the ones that
--- weren't open are loaded hidden, and saved after `fn` (what was open stays
--- as you left it, unsaved). The batch is remembered for M.undo_last().
--- Returns what `fn` returns.
function M.batch(label, files, fn)
	local notes, seen = {}, {}
	for _, file in ipairs(files) do
		local path = normalize(file)
		if not seen[path] and vim.fn.filereadable(path) == 1 then
			seen[path] = true
			local bufnr = vim.fn.bufnr(path)
			local loaded = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)
			-- "open": a buffer you have (listed, or in a window); a hidden one
			-- an earlier batch loaded counts as not open
			local open = loaded and (vim.bo[bufnr].buflisted or #vim.fn.win_findbuf(bufnr) > 0)
			if not loaded then
				bufnr = vim.fn.bufadd(path)
				vim.bo[bufnr].buflisted = false
				vim.fn.bufload(bufnr)
			elseif not vim.bo[bufnr].modified then
				pcall(vim.cmd, "silent! checktime " .. bufnr)
			end
			notes[#notes + 1] = {
				bufnr = bufnr,
				path = path,
				seq = seq_of(bufnr),
				tick = vim.api.nvim_buf_get_changedtick(bufnr),
				save = not open,
			}
		end
	end
	local results = { pcall(fn) }
	local changed = {}
	for _, n in ipairs(notes) do
		if vim.api.nvim_buf_get_changedtick(n.bufnr) ~= n.tick then
			if n.save then
				vim.api.nvim_buf_call(n.bufnr, function()
					vim.cmd("silent update")
				end)
				Document.invalidate(n.path)
			end
			changed[#changed + 1] = n
		end
	end
	if #changed > 0 then
		last = { label = label, notes = changed }
	end
	if not results[1] then
		error(results[2], 0)
	end
	return unpack(results, 2, table.maxn(results))
end

--- The last batch: { label, files } or nil.
function M.last_batch()
	if not last then
		return nil
	end
	local files = {}
	for _, n in ipairs(last.notes) do
		files[#files + 1] = n.path
	end
	return { label = last.label, files = files }
end

--- Undo the last batch in every note it changed (saving the ones it saved).
--- Returns its label, or nil and why not.
function M.undo_last()
	if not last then
		return nil, "nothing to undo"
	end
	local batch = last
	last = nil
	for _, n in ipairs(batch.notes) do
		if vim.api.nvim_buf_is_valid(n.bufnr) then
			if not vim.api.nvim_buf_is_loaded(n.bufnr) then
				vim.fn.bufload(n.bufnr)
			end
			vim.api.nvim_buf_call(n.bufnr, function()
				vim.cmd("silent undo " .. n.seq)
				if n.save then
					vim.cmd("silent update")
				end
			end)
			Document.invalidate(n.path)
			Events.emit("workspace:lines_changed", { file = n.path, start_line = 1, end_line = -1, count = 0 })
		end
	end
	return batch.label
end

-- =============================================================================
-- Cursor context
-- =============================================================================

local function is_note_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local ext = require("zortex.config").extension or ".zortex"
	return name ~= "" and name:sub(-#ext) == ext
end

--- Context of the cursor in a note buffer, or nil outside notes:
--- { bufnr, filepath, doc, section, lnum, col, line }
function M.get_doc_context()
	local bufnr = vim.api.nvim_get_current_buf()
	if not is_note_buffer(bufnr) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local doc = Document.from_buffer(bufnr)
	return {
		bufnr = bufnr,
		filepath = doc.filepath,
		doc = doc,
		section = doc:node_at(cursor[1]),
		lnum = cursor[1],
		col = cursor[2],
		line = doc.lines[cursor[1]] or "",
	}
end

function M.setup() end

return M
