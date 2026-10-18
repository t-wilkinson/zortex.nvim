-- features/archive.lua - Move a section into z/archive.<note>.zortex
local M = {}

local syntax = require("zortex.core.syntax")
local Document = require("zortex.core.document")
local link_mod = require("zortex.core.link")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")
local Config = require("zortex.config")

-- =============================================================================
-- Archive Path Generation
-- =============================================================================

-- Generate archive file path from original file path
local function get_archive_path(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local filename = vim.fn.fnamemodify(filepath, ":t:r") -- filename without extension
	local ext = vim.fn.fnamemodify(filepath, ":e")

	-- Ensure z directory exists
	local archive_dir = fs.joinpath(dir, "z")
	vim.fn.mkdir(archive_dir, "p")

	return fs.joinpath(archive_dir, "archive." .. filename .. "." .. ext)
end

-- =============================================================================
-- Archive File Management
-- =============================================================================

-- Get or create archive file with proper headers
local function ensure_archive_file(archive_path, original_lines)
	if vim.fn.filereadable(archive_path) == 0 then
		-- Create new archive file with tags from original
		local header_lines = {}

		-- Copy all article names and tags from original
		for _, line in ipairs(original_lines) do
			if line:match("^@@") or line:match("^@%w") then
				table.insert(header_lines, line)
			else
				-- Stop at first non-tag line
				break
			end
		end

		-- Mark the file archived so link resolution and projects skip it
		if not syntax.list_has(syntax.parse_header(header_lines).tags, constants.ARCHIVE_TAG) then
			table.insert(header_lines, "@" .. constants.ARCHIVE_TAG)
		end

		-- Add empty line after headers
		table.insert(header_lines, "")

		fs.write_lines(archive_path, header_lines)
	end

	return fs.read_lines(archive_path) or {}
end

-- =============================================================================
-- Section Merging
-- =============================================================================

-- Header lines of a section and its ancestors (the article excluded):
-- { { line, level }, ... } outermost first.
local function section_path(lines, node)
	local path = {}
	for _, n in ipairs(node:get_full_path()) do
		if not n:is_root() and n.type ~= constants.SECTION_TYPE.ARTICLE then
			path[#path + 1] = { line = lines[n.start_line], level = n.level }
		end
	end
	return path
end

-- Merge `content` (a section, header first) into the archive under the same
-- ancestors, creating the ancestors that are missing. Existing sections are
-- matched by their exact header line; new content goes at the end of the
-- deepest existing one.
local function merge_into_archive(archive_lines, path, content)
	local doc = Document.from_lines(archive_lines)
	local parent = doc:article() or doc.tree
	local depth = 0
	for i = 1, #path do
		local found
		for _, child in ipairs(parent.children) do
			if archive_lines[child.start_line] == path[i].line then
				found = child
				break
			end
		end
		if not found then
			break
		end
		parent, depth = found, i
	end

	local to_insert = {}
	if depth == #path then
		-- The section itself already exists: add the new content to it
		for i = 2, #content do
			to_insert[#to_insert + 1] = content[i]
		end
	else
		for i = depth + 1, #path - 1 do
			to_insert[#to_insert + 1] = path[i].line
		end
		vim.list_extend(to_insert, content)
	end

	local at = (parent:is_root() and #archive_lines or parent.end_line) + 1
	for i = #to_insert, 1, -1 do
		table.insert(archive_lines, at, to_insert[i])
	end
	return archive_lines
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Archive the section at current cursor position
function M.archive_current_section()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	if not filepath:match(Config.extension .. "$") then
		vim.notify("Not a Zortex file", vim.log.levels.ERROR)
		return
	end

	local doc = Document.from_buffer(bufnr)
	local node = doc:node_at(cursor_line)
	if node:is_root() or node.type == constants.SECTION_TYPE.ARTICLE then
		vim.notify("No section found at cursor position", vim.log.levels.WARN)
		return
	end

	local lines = doc.lines
	local content = doc:get_lines(node.start_line, node.end_line)
	local archive_path = get_archive_path(filepath)
	local archive_lines = ensure_archive_file(archive_path, lines)
	archive_lines = merge_into_archive(archive_lines, section_path(lines, node), content)
	fs.write_lines(archive_path, archive_lines)

	local link = link_mod.build_link(link_mod.node_components(doc, node))
	vim.api.nvim_buf_set_lines(bufnr, node.start_line - 1, node.end_line, false, {})

	vim.notify(string.format("Archived section to %s\nLink: %s", archive_path, link), vim.log.levels.INFO)
end


--- Archive the section starting on `lnum` of `file` (a done project, from
--- the weekly review) into its note's z/archive file, as one batch
--- (core/workspace): :ZortexUndo takes it back. Returns the archive's path,
--- or nil and why not.
function M.archive_section_at(file, lnum)
	local workspace = require("zortex.core.workspace")
	local doc = workspace.document(file)
	local node = doc and doc:node_starting_at(lnum)
	if not node or node:is_root() or node.type == constants.SECTION_TYPE.ARTICLE then
		return nil, "no section starts there"
	end
	local archive_path = get_archive_path(file)
	ensure_archive_file(archive_path, doc.lines)
	Document.invalidate(archive_path)
	return workspace.batch("archive a section", { file, archive_path }, function()
		doc = workspace.document(file)
		node = doc:node_starting_at(lnum)
		if not node then
			return nil, "the note changed: refresh and try again"
		end
		local content = doc:get_lines(node.start_line, node.end_line)
		local old = workspace.get_lines(archive_path)
		local merged = merge_into_archive(vim.deepcopy(old), section_path(doc.lines, node), content)
		local ok, err = workspace.set_lines(archive_path, 1, #old, merged)
		if not ok then
			return nil, err
		end
		ok, err = workspace.delete_lines(file, node.start_line, node.end_line)
		if not ok then
			return nil, err
		end
		return archive_path
	end)
end

-- =============================================================================
-- Archiving a finished task
-- =============================================================================

--- The archive for finished tasks that served neither a key result nor an
--- area: z/archive.tasks.zortex (made when missing).
function M.tasks_archive_path()
	local dir = fs.joinpath(Config.notes_dir, "z")
	vim.fn.mkdir(dir, "p")
	return fs.joinpath(dir, "archive.tasks" .. (Config.extension or ".zortex"))
end

--- Move the task on `lnum` of `file` (with the lines nested under it) to
--- z/archive.tasks.zortex, under a heading naming the note it came from.
--- One batch (core/workspace): :ZortexUndo takes it back. Returns the
--- archive's path, or nil and why not.
function M.archive_task(file, lnum)
	local workspace = require("zortex.core.workspace")
	local Move = require("zortex.services.move")
	local doc = workspace.document(file)
	if not doc then
		return nil, "can't read " .. file
	end
	local path = M.tasks_archive_path()
	if vim.fn.filereadable(path) == 0 then
		fs.write_lines(path, { "@@Archived tasks", "@" .. constants.ARCHIVE_TAG, "" })
		Document.invalidate(path)
	end
	local from = doc:name() or vim.fn.fnamemodify(file, ":t:r")
	return workspace.batch("archive a task", { file, path }, function()
		local src, err = Move.source(workspace.document(file), lnum)
		if not src then
			return nil, err
		end
		-- the heading for its note, at the end of the archive when new
		local lines = workspace.get_lines(path)
		local heading
		for i, l in ipairs(lines) do
			if l == "# " .. from then
				heading = i
			end
		end
		if not heading then
			local add = { "# " .. from }
			if lines[#lines] and lines[#lines]:match("%S") then
				table.insert(add, 1, "")
			end
			local ok, ierr = workspace.insert_lines(path, #lines + 1, add)
			if not ok then
				return nil, ierr
			end
			heading = #lines + #add
		end
		local dst, derr = Move.target(workspace.document(path), heading, src)
		if not dst then
			return nil, derr
		end
		local at, merr = Move.move(file, src, path, dst)
		if not at then
			return nil, merr
		end
		return path
	end)
end

return M
