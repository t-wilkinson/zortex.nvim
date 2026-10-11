-- core/workspace.lua - Editing notes
--
-- Reads go through core/document (cached snapshots that prefer a modified
-- buffer over the file). Writes go through this module:
--
--   * if the note is loaded in a buffer, the buffer is edited (you save it as
--     usual, undo works, other plugins see the change)
--   * otherwise the file on disk is edited directly
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
	return (path and fs.read_lines(path)) or {}
end

--- Snapshot of a note (see core/document).
function M.document(target)
	local bufnr, path = resolve_target(target)
	if bufnr then
		return Document.from_buffer(bufnr)
	end
	return path and Document.get(path) or nil
end

--- Replace lines start_line..end_line (1-based, inclusive) with `lines`.
--- Use end_line = start_line - 1 to insert before start_line.
---@return boolean ok, string? err
function M.set_lines(target, start_line, end_line, lines)
	if type(lines) == "string" then
		lines = { lines }
	end
	local bufnr, path = resolve_target(target)

	if bufnr then
		vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, lines)
	else
		if not path then
			return false, "No file for target"
		end
		local current = fs.read_lines(path) or {}
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
