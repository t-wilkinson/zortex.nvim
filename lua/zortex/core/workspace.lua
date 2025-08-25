-- core/workspace.lua - Centralized workspace management for core Zortex files
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local Section = require("zortex.core.section")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

-- =============================================================================
-- Document Class
-- =============================================================================

local Document = {}
Document.__index = Document

function Document:new(opts)
	local doc = setmetatable({}, self)

	-- Core properties
	doc.name = opts.name -- "projects", etc.
	doc.filepath = opts.filepath
	doc.bufnr = nil -- Buffer number if loaded
	doc.exists = false -- File exists on disk

	-- Content
	doc.lines = {} -- Current lines (source of truth)
	doc.original_lines = {} -- Lines from last save/load
	doc.sections = nil -- Parsed section tree
	doc.article_names = {} -- Extracted article names
	doc.ids = nil

	-- Change tracking
	doc.dirty_lines = {} -- Set of modified line numbers
	doc.dirty_sections = {} -- Set of sections needing reparse
	doc.pending_changes = {} -- Queue of pending changes
	doc.needs_full_reparse = false -- Full document reparse needed

	-- Metadata
	doc.last_modified = 0 -- Timestamp of last modification
	doc.last_parsed = 0 -- Timestamp of last parse
	doc.checksum = nil -- Content checksum for comparison
	doc.file_mtime = 0 -- File modification time

	-- Sync state
	doc._syncing = false -- Prevent recursive syncing
	doc._attaching = false -- Prevent recursive attachment
	doc._parse_timer = nil -- Debounced parse timer

	return doc
end

-- Load document from file
function Document:load()
	local timer = Logger.start_timer("workspace.document.load")

	if fs.file_exists(self.filepath) then
		self.lines = fs.read_lines(self.filepath) or {}
		self.exists = true
		-- Get file modification time
		local stat = vim.loop.fs_stat(self.filepath)
		if stat then
			self.file_mtime = stat.mtime.sec
		end
	else
		-- Initialize with default content for special files
		self.lines = self:_get_default_content()
		self.exists = false
	end

	self.original_lines = vim.deepcopy(self.lines)
	self.checksum = self:_calculate_checksum()
	self.last_modified = os.time()

	-- Parse immediately
	self:parse()

	timer()

	Events.emit("workspace:document_loaded", {
		name = self.name,
		filepath = self.filepath,
		line_count = #self.lines,
	})

	return self
end

-- Check if file has been modified externally
function Document:check_external_changes()
	if not self.exists or not fs.file_exists(self.filepath) then
		return false
	end

	local stat = vim.loop.fs_stat(self.filepath)
	if not stat then
		return false
	end

	if stat.mtime.sec > self.file_mtime then
		-- Logger.info("workspace", "External file change detected", {
		-- 	name = self.name,
		-- 	old_mtime = self.file_mtime,
		-- 	new_mtime = stat.mtime.sec,
		-- })

		-- Reload the file
		self:reload()
		return true
	end

	return false
end

-- Reload document from file
function Document:reload()
	local timer = Logger.start_timer("workspace.document.reload")

	-- Save current buffer state if attached
	local had_buffer = self.bufnr ~= nil
	local bufnr = self.bufnr

	-- Detach from buffer temporarily
	if had_buffer then
		self:detach_buffer()
	end

	-- Reload from file
	self:load()

	-- Reattach to buffer if it still exists
	if had_buffer and vim.api.nvim_buf_is_valid(bufnr) then
		self:attach_buffer(bufnr)
	end

	timer()

	Events.emit("workspace:document_reloaded", {
		name = self.name,
		filepath = self.filepath,
	})
end

-- Save document to file
function Document:save()
	if not self:is_dirty() then
		return true
	end

	local timer = Logger.start_timer("workspace.document.save")

	-- Write to file
	local success = fs.write_lines(self.filepath, self.lines)

	if success then
		self.original_lines = vim.deepcopy(self.lines)
		self.dirty_lines = {}
		self.pending_changes = {}
		self.checksum = self:_calculate_checksum()
		self.exists = true

		-- Update file modification time
		local stat = vim.loop.fs_stat(self.filepath)
		if stat then
			self.file_mtime = stat.mtime.sec
		end

		Events.emit("workspace:document_saved", {
			name = self.name,
			filepath = self.filepath,
		})
	else
		Logger.error("workspace", "Failed to save document", {
			name = self.name,
			filepath = self.filepath,
		})
	end

	timer()
	return success
end

-- Attach to buffer
function Document:attach_buffer(bufnr)
	-- Prevent recursive attachment
	if self._attaching then
		return
	end

	if self.bufnr and self.bufnr ~= bufnr then
		self:detach_buffer()
	end

	self._attaching = true
	self.bufnr = bufnr

	-- Check for external changes first
	self:check_external_changes()

	-- Sync lines to buffer only if they differ
	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not self:_lines_equal(buffer_lines, self.lines) then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, self.lines)
	end

	-- Set up buffer autocmds
	self:_setup_buffer_autocmds()

	self._attaching = false

	Events.emit("workspace:buffer_attached", {
		name = self.name,
		bufnr = bufnr,
	})
end

-- Detach from buffer
function Document:detach_buffer()
	if not self.bufnr then
		return
	end

	-- Cancel parse timer if pending
	if self._parse_timer then
		self._parse_timer:stop()
		self._parse_timer = nil
	end

	-- Clear autocmds
	local group_name = string.format("ZortexWorkspace_%s_%d", self.name, self.bufnr)
	pcall(vim.api.nvim_del_augroup_by_name, group_name)

	Events.emit("workspace:buffer_detached", {
		name = self.name,
		bufnr = self.bufnr,
	})

	self.bufnr = nil
end

-- =============================================================================
-- Line Modification API
-- =============================================================================

-- Get lines
function Document:get_lines(start_line, end_line)
	start_line = start_line or 1
	end_line = end_line or #self.lines

	local result = {}
	for i = start_line, math.min(end_line, #self.lines) do
		table.insert(result, self.lines[i])
	end
	return result
end

-- Get single line
function Document:get_line(lnum)
	return self.lines[lnum]
end

-- Add line(s)
function Document:add_lines(lnum, lines_to_add)
	if type(lines_to_add) == "string" then
		lines_to_add = { lines_to_add }
	end

	-- Record change
	table.insert(self.pending_changes, {
		type = "add",
		lnum = lnum,
		lines = lines_to_add,
		timestamp = os.time(),
	})

	-- Apply change
	for i, line in ipairs(lines_to_add) do
		table.insert(self.lines, lnum + i - 1, line)
	end

	-- Mark affected lines as dirty
	for i = lnum, lnum + #lines_to_add - 1 do
		self.dirty_lines[i] = true
	end

	-- Mark sections for reparse
	self:_mark_sections_dirty(lnum, lnum + #lines_to_add - 1)

	-- Update buffer if attached
	if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
		self._syncing = true
		vim.api.nvim_buf_set_lines(self.bufnr, lnum - 1, lnum - 1, false, lines_to_add)
		self._syncing = false
	end

	self.last_modified = os.time()

	-- Schedule reparse
	self:_schedule_reparse()

	Events.emit("workspace:lines_added", {
		document = self.name,
		lnum = lnum,
		count = #lines_to_add,
	})

	return true
end

function Document:change_line(lnum, new_line)
	return self:change_lines(lnum, lnum, { new_line })
end

-- Change line(s)
function Document:change_lines(start_line, end_line, new_lines)
	if type(new_lines) == "string" then
		new_lines = { new_lines }
	end

	-- Record change
	table.insert(self.pending_changes, {
		type = "change",
		start_line = start_line,
		end_line = end_line,
		old_lines = self:get_lines(start_line, end_line),
		new_lines = new_lines,
		timestamp = os.time(),
	})

	-- Apply change
	for i = start_line, end_line do
		if self.lines[i] then
			table.remove(self.lines, start_line)
		end
	end

	for i, line in ipairs(new_lines) do
		table.insert(self.lines, start_line + i - 1, line)
	end

	-- Mark affected lines as dirty
	local new_end = start_line + #new_lines - 1
	for i = start_line, new_end do
		self.dirty_lines[i] = true
	end

	-- Mark sections for reparse
	self:_mark_sections_dirty(start_line, math.max(end_line, new_end))

	-- Update buffer if attached
	if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
		self._syncing = true
		vim.api.nvim_buf_set_lines(self.bufnr, start_line - 1, end_line, false, new_lines)
		vim.cmd("redraw")
		self._syncing = false
	end

	self.last_modified = os.time()

	-- Schedule reparse
	self:_schedule_reparse()

	Events.emit("workspace:lines_changed", {
		document = self.name,
		start_line = start_line,
		end_line = end_line,
		new_count = #new_lines,
	})

	return true
end

-- Delete line(s)
function Document:delete_lines(start_line, end_line)
	end_line = end_line or start_line

	-- Record change
	table.insert(self.pending_changes, {
		type = "delete",
		start_line = start_line,
		end_line = end_line,
		old_lines = self:get_lines(start_line, end_line),
		timestamp = os.time(),
	})

	-- Apply change
	for i = end_line, start_line, -1 do
		table.remove(self.lines, i)
	end

	-- Mark sections for reparse
	self:_mark_sections_dirty(start_line, end_line)

	-- Update buffer if attached
	if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
		self._syncing = true
		vim.api.nvim_buf_set_lines(self.bufnr, start_line - 1, end_line, false, {})
		self._syncing = false
	end

	self.last_modified = os.time()

	-- Schedule reparse
	self:_schedule_reparse()

	Events.emit("workspace:lines_deleted", {
		document = self.name,
		start_line = start_line,
		end_line = end_line,
	})

	return true
end

-- Update single line (convenience)
function Document:update_line(lnum, new_text)
	return self:change_lines(lnum, lnum, { new_text })
end

-- =============================================================================
-- Section Management
-- =============================================================================

-- Parse document sections
function Document:parse(force)
	if not force and not self:_needs_parse() then
		return self.sections
	end

	local timer = Logger.start_timer("workspace.document.parse")

	-- Extract article names first
	self.article_names = self:_extract_article_names()

	-- Build section tree
	local builder = Section.SectionTreeBuilder:new()
	local code_tracker = parser.CodeBlockTracker:new()

	for line_num, line in ipairs(self.lines) do
		builder:update_current_end(line_num)

		local in_code_block = code_tracker:update(line)
		if not in_code_block then
			local section = Section.create_from_line(line, line_num, in_code_block)
			if section then
				builder:add_section(section)
			end
		end
	end

	self.sections = builder:get_tree()
	self.sections.end_line = #self.lines

	-- Clear dirty tracking
	self.dirty_sections = {}
	self.needs_full_reparse = false
	self.last_parsed = os.time()

	timer()

	Events.emit("workspace:document_parsed", {
		name = self.name,
	})

	return self.sections
end

-- Reparse only dirty sections
function Document:reparse_dirty()
	if self.needs_full_reparse then
		return self:parse(true)
	end

	if vim.tbl_isempty(self.dirty_sections) then
		return self.sections
	end

	local timer = Logger.start_timer("workspace.document.reparse_dirty")

	-- For now, do a full reparse
	-- TODO: Implement incremental parsing
	self:parse(true)

	timer()

	return self.sections
end

-- Get section at line
function Document:get_section_at_line(lnum)
	if not self.sections then
		self:parse()
	end

	local function find_section(section)
		if section:contains_line(lnum) then
			-- Check children for more specific match
			for _, child in ipairs(section.children) do
				local child_match = find_section(child)
				if child_match then
					return child_match
				end
			end
			return section
		end
		return nil
	end

	return find_section(self.sections)
end

-- =============================================================================
-- State Management
-- =============================================================================

-- Check if document is dirty
function Document:is_dirty()
	return not vim.tbl_isempty(self.dirty_lines) or not vim.tbl_isempty(self.pending_changes)
end

-- Get pending changes
function Document:get_pending_changes()
	return vim.deepcopy(self.pending_changes)
end

-- Clear pending changes
function Document:clear_pending_changes()
	self.pending_changes = {}
	self.dirty_lines = {}
end

-- Undo last change
function Document:undo()
	if #self.pending_changes == 0 then
		return false
	end

	local change = table.remove(self.pending_changes)

	-- Apply reverse of change
	if change.type == "add" then
		-- Remove added lines
		for i = 1, #change.lines do
			table.remove(self.lines, change.lnum)
		end
	elseif change.type == "change" then
		-- Restore old lines
		for i = change.start_line, change.start_line + #change.new_lines - 1 do
			table.remove(self.lines, change.start_line)
		end
		for i, line in ipairs(change.old_lines) do
			table.insert(self.lines, change.start_line + i - 1, line)
		end
	elseif change.type == "delete" then
		-- Restore deleted lines
		for i, line in ipairs(change.old_lines) do
			table.insert(self.lines, change.start_line + i - 1, line)
		end
	end

	-- Mark for reparse
	self.needs_full_reparse = true

	-- Update buffer if attached
	if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
		self._syncing = true
		vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.lines)
		self._syncing = false
	end

	-- Reparse immediately after undo
	self:parse(true)

	return true
end

-- =============================================================================
-- IDs
-- =============================================================================
function Document:get_ids()
	local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)

	local all_ids = {}
	for _, line in ipairs(lines) do
		for match in string.gmatch(line, "@id%((%w+)%)") do
			table.insert(all_ids, match)
		end
	end

	return all_ids
end

-- =============================================================================
-- Private Methods
-- =============================================================================

function Document:_get_default_content()
	local defaults = {
		projects = {
			"@@Projects",
			"@@P",
			"",
		},
		areas = {
			"@@Areas",
			"@@A",
			"",
		},
		okr = {
			"@@OKR",
			"@@Objectives",
			"",
		},
		projects_archive = {
			"@@Projects",
			"@@P",
			"@Archive",
		},
	}

	return defaults[self.name] or { "@@" .. self.name:gsub("^%l", string.upper), "" }
end

function Document:_extract_article_names()
	local names = {}
	local code_tracker = parser.CodeBlockTracker:new()

	for i = 1, math.min(10, #self.lines) do
		local in_code_block = code_tracker:update(self.lines[i])
		if not in_code_block then
			local name = parser.extract_article_name(self.lines[i])
			if name then
				table.insert(names, name)
			elseif self.lines[i]:match("%S") then
				-- Stop at first non-article line
				break
			end
		end
	end

	return names
end

function Document:_calculate_checksum()
	local content = table.concat(self.lines, "\n")
	return vim.fn.sha256(content)
end

function Document:_needs_parse()
	return self.sections == nil
		or self.needs_full_reparse
		or not vim.tbl_isempty(self.dirty_sections)
		or (os.time() - self.last_parsed) > 60 -- Reparse after 1 minute
end

function Document:_mark_sections_dirty(start_line, end_line)
	-- Find sections that overlap with the changed range
	if not self.sections then
		self.needs_full_reparse = true
		return
	end

	local function mark_overlapping(section)
		if section.start_line <= end_line and section.end_line >= start_line then
			self.dirty_sections[section:get_id()] = true
		end

		for _, child in ipairs(section.children) do
			mark_overlapping(child)
		end
	end

	mark_overlapping(self.sections)
end

function Document:_lines_equal(lines1, lines2)
	if #lines1 ~= #lines2 then
		return false
	end
	for i = 1, #lines1 do
		if lines1[i] ~= lines2[i] then
			return false
		end
	end
	return true
end

function Document:_schedule_reparse()
	-- Cancel existing timer
	if self._parse_timer then
		self._parse_timer:stop()
	end

	-- Create new timer for debounced parsing
	self._parse_timer = vim.loop.new_timer()
	self._parse_timer:start(
		100, -- 100ms delay
		0,
		vim.schedule_wrap(function()
			self:parse()
			self._parse_timer = nil
		end)
	)
end

function Document:_setup_buffer_autocmds()
	if not self.bufnr then
		return
	end

	local group_name = string.format("ZortexWorkspace_%s_%d", self.name, self.bufnr)
	local group = vim.api.nvim_create_augroup(group_name, { clear = true })

	-- Track buffer changes
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = self.bufnr,
		callback = function()
			-- Skip if we're already syncing
			if not self._syncing then
				self:_sync_from_buffer()
			end
		end,
	})

	-- Handle buffer unload
	vim.api.nvim_create_autocmd("BufUnload", {
		group = group,
		buffer = self.bufnr,
		callback = function()
			self:detach_buffer()
		end,
	})

	-- Check for external changes on buffer enter
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		buffer = self.bufnr,
		callback = function()
			self:check_external_changes()
		end,
	})

	-- Check for external changes on focus gained
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		buffer = self.bufnr,
		callback = function()
			self:check_external_changes()
		end,
	})
end

function Document:_sync_from_buffer()
	if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
		return
	end

	-- Prevent recursive syncing
	if self._syncing then
		return
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)

	-- Simple comparison for now
	-- TODO: Implement diff algorithm for better change tracking
	if #buffer_lines ~= #self.lines then
		self.lines = buffer_lines
		self.needs_full_reparse = true
		self.last_modified = os.time()

		-- Mark all as dirty
		for i = 1, #self.lines do
			self.dirty_lines[i] = true
		end

		-- Schedule reparse
		self:_schedule_reparse()
	else
		-- Check for line changes
		local has_changes = false
		for i, line in ipairs(buffer_lines) do
			if line ~= self.lines[i] then
				self.lines[i] = line
				self.dirty_lines[i] = true
				self:_mark_sections_dirty(i, i)
				has_changes = true
			end
		end

		if has_changes then
			self.last_modified = os.time()
			-- Schedule reparse
			self:_schedule_reparse()
		end
	end
end

-- =============================================================================
-- Workspace Manager
-- =============================================================================

local Workspace = {
	documents = {},
	initialized = false,
	external_check_timer = nil,
}

-- Initialize workspace
function Workspace:init()
	if self.initialized then
		return
	end

	local timer = Logger.start_timer("workspace.init")

	-- Define core documents
	local core_docs = {
		projects = constants.FILES.PROJECTS,
		areas = constants.FILES.AREAS,
		okr = constants.FILES.OKR,
		projects_archive = constants.FILES.PROJECTS_ARCHIVE,
	}

	-- Create document instances
	for name, filename in pairs(core_docs) do
		local filepath = fs.get_file_path(filename)
		self.documents[name] = Document:new({
			name = name,
			filepath = filepath,
		})

		-- Load document
		self.documents[name]:load()

		-- Create accessor
		self[name] = self.documents[name]
	end

	-- Set up auto-save
	self:_setup_autosave()

	-- Set up buffer watchers
	self:_setup_buffer_watchers()

	-- Set up external change monitoring
	self:_setup_external_monitoring()

	self.initialized = true

	timer()

	Events.emit("workspace:initialized", {
		documents = vim.tbl_keys(self.documents),
	})
end

-- Get document by name
function Workspace:get(name)
	return self.documents[name]
end

-- Get document for buffer
function Workspace:get_for_buffer(bufnr)
	local buffer_path = vim.api.nvim_buf_get_name(bufnr)
	if buffer_path == "" then
		return nil
	end

	-- Extract just the filename from the buffer path
	local buffer_filename = vim.fn.fnamemodify(buffer_path, ":t")

	-- Check each document by comparing filenames
	for name, doc in pairs(self.documents) do
		local doc_filename = vim.fn.fnamemodify(doc.filepath, ":t")
		if buffer_filename == doc_filename then
			return doc
		end
	end

	return nil
end

-- Open document in buffer
function Workspace:open(name, opts)
	opts = opts or {}
	local doc = self:get(name)

	if not doc then
		Logger.error("workspace", "Unknown document", { name = name })
		return nil
	end

	-- Check if already open
	if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
		-- Switch to existing buffer
		local wins = vim.fn.win_findbuf(doc.bufnr)
		if #wins > 0 then
			vim.api.nvim_set_current_win(wins[1])
		else
			vim.cmd((opts.cmd or "edit") .. " #" .. doc.bufnr)
		end
		return doc.bufnr
	end

	-- Open file
	vim.cmd((opts.cmd or "edit") .. " " .. vim.fn.fnameescape(doc.filepath))
	local bufnr = vim.api.nvim_get_current_buf()

	-- Attach document to buffer
	doc:attach_buffer(bufnr)

	return bufnr
end

-- Save all dirty documents
function Workspace:save_all()
	local saved = {}

	for name, doc in pairs(self.documents) do
		if doc:is_dirty() then
			if doc:save() then
				table.insert(saved, name)
			end
		end
	end

	if #saved > 0 then
		Logger.info("workspace", "Saved documents", { documents = saved })
	end

	return saved
end

-- Save specific document
function Workspace:save(name)
	local doc = self:get(name)
	if doc then
		return doc:save()
	end
	return false
end

-- Check all documents for external changes
function Workspace:check_all_external_changes()
	for name, doc in pairs(self.documents) do
		doc:check_external_changes()
	end
end

-- Private: Set up auto-save
function Workspace:_setup_autosave()
	local group = vim.api.nvim_create_augroup("ZortexWorkspaceAutoSave", { clear = true })

	-- Save on Vim leave
	-- vim.api.nvim_create_autocmd("VimLeavePre", {
	-- 	group = group,
	-- 	callback = function()
	-- 		self:save_all()
	-- 	end,
	-- })

	-- Periodic save (every 5 minutes)
	-- local timer = vim.loop.new_timer()
	-- timer:start(
	-- 	300000,
	-- 	300000,
	-- 	vim.schedule_wrap(function()
	-- 		self:save_all()
	-- 	end)
	-- )
end

-- Private: Set up buffer watchers
function Workspace:_setup_buffer_watchers()
	local group = vim.api.nvim_create_augroup("ZortexWorkspaceBuffers", { clear = true })
	local Config = require("zortex.config")

	-- Watch for buffer reads
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "*" .. Config.extension,
		callback = function(args)
			-- Delay slightly to ensure buffer is fully loaded
			vim.defer_fn(function()
				local doc = self:get_for_buffer(args.buf)
				if doc and not doc.bufnr then
					doc:attach_buffer(args.buf)
				end
			end, 0)
		end,
	})

	-- Watch for new buffers
	vim.api.nvim_create_autocmd("BufNew", {
		group = group,
		pattern = "*" .. Config.extension,
		callback = function(args)
			-- Delay slightly to ensure buffer is set up
			vim.defer_fn(function()
				local doc = self:get_for_buffer(args.buf)
				if doc and not doc.bufnr then
					doc:attach_buffer(args.buf)
				end
			end, 0)
		end,
	})
end

-- Private: Set up external file monitoring
function Workspace:_setup_external_monitoring()
	-- Check for external changes periodically
	-- self.external_check_timer = vim.loop.new_timer()
	-- self.external_check_timer:start(
	-- 	5000, -- Initial delay 5 seconds
	-- 	30000, -- Check every 30 seconds
	-- 	vim.schedule_wrap(function()
	-- 		self:check_all_external_changes()
	-- 	end)
	-- )

	-- -- Also check on various vim events
	-- local group = vim.api.nvim_create_augroup("ZortexWorkspaceExternal", { clear = true })

	-- vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
	-- 	group = group,
	-- 	callback = function()
	-- 		self:check_all_external_changes()
	-- 	end,
	-- })
end

-- =============================================================================
-- Module API
-- =============================================================================

-- Initialize on module load
M.init = function()
	Workspace:init()
end

-- Document access
M.get = function(name)
	return Workspace:get(name)
end

M.get_all_documents = function()
	return Workspace.documents
end

M.get_current = function()
	local bufnr = vim.api.nvim_get_current_buf()
	return Workspace:get_for_buffer(bufnr)
end

-- Get the document context of the cursor
M.get_doc_context = function()
	local bufnr = vim.api.nvim_get_current_buf()
	local doc = Workspace:get_for_buffer(bufnr)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local lnum = cursor[1]
	local col = cursor[2]

	if doc == nil then
		return nil
	end

	if not doc.bufnr then
		doc:attach_buffer(bufnr)
	end

	local line = doc:get_line(lnum)

	return {
		bufnr = bufnr,
		doc = doc,
		section = doc:get_section_at_line(lnum),
		lnum = lnum,
		col = col,
		line = line,
	}
end

M.projects = function()
	return Workspace.documents.projects
end

M.projects_archive = function()
	return Workspace.documents.projects_archive
end

M.areas = function()
	return Workspace.documents.areas
end

M.okr = function()
	return Workspace.documents.okr
end

-- Operations
M.open = function(name, opts)
	return Workspace:open(name, opts)
end

M.save = function(name)
	if name then
		return Workspace:save(name)
	else
		return Workspace:save_all()
	end
end

M.save_all = function()
	return Workspace:save_all()
end

-- Force check for external changes
M.check_external_changes = function()
	return Workspace:check_all_external_changes()
end

-- Setup function for lazy loading
M.setup = function(opts)
	Workspace:init()
end

return M
