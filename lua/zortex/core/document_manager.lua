-- core/document_manager.lua - Enhanced with incremental parsing
local M = {}

local Events = require("zortex.core.event_bus")
local Section = require("zortex.core.section")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local Config = require("zortex.config")
local constants = require("zortex.constants")
local Logger = require("zortex.core.logger")

local cfg = {}

-- =============================================================================
-- Sync Strategies
-- =============================================================================

local SYNC_STRATEGY = {
	IMMEDIATE = "immediate",
	BATCHED = "batched",
	ON_SAVE = "on_save",
}

-- =============================================================================
-- Change Types for Incremental Parsing
-- =============================================================================

local CHANGE_TYPE = {
	INSERT = "insert",
	DELETE = "delete",
	MODIFY = "modify",
}

-- =============================================================================
-- Dirty Range Class
-- =============================================================================

local DirtyRange = {}
DirtyRange.__index = DirtyRange

function DirtyRange:new(start_line, end_line, change_type, line_delta)
	return setmetatable({
		start_line = start_line,
		end_line = end_line,
		change_type = change_type or CHANGE_TYPE.MODIFY,
		line_delta = line_delta or 0, -- How many lines were added/removed
		timestamp = vim.loop.hrtime(),
	}, self)
end

function DirtyRange:overlaps(other)
	return not (self.end_line < other.start_line or other.end_line < self.start_line)
end

function DirtyRange:merge(other)
	self.start_line = math.min(self.start_line, other.start_line)
	self.end_line = math.max(self.end_line, other.end_line)
	self.line_delta = self.line_delta + other.line_delta

	-- If we have both inserts and deletes, it's a modify
	if self.change_type ~= other.change_type then
		self.change_type = CHANGE_TYPE.MODIFY
	end
end

-- =============================================================================
-- LRU Cache Implementation
-- =============================================================================

local LRU = {}
LRU.__index = LRU

function LRU:new(opts)
	return setmetatable({
		max_items = opts.max_items or 20,
		items = {},
		order = {},
	}, self)
end

function LRU:get(key)
	local item = self.items[key]
	if item then
		self:_touch(key)
	end
	return item
end

function LRU:set(key, value)
	if self.items[key] then
		self.items[key] = value
		self:_touch(key)
	else
		table.insert(self.order, 1, key)
		self.items[key] = value

		if #self.order > self.max_items then
			local evicted_key = table.remove(self.order)
			self.items[evicted_key] = nil
			Events.emit("document:evicted", { filepath = evicted_key })
		end
	end
end

function LRU:_touch(key)
	for i, k in ipairs(self.order) do
		if k == key then
			table.remove(self.order, i)
			table.insert(self.order, 1, key)
			break
		end
	end
end

-- =============================================================================
-- Document Class
-- =============================================================================

local Document = {}
Document.__index = Document

function Document:new(opts)
	return setmetatable({
		-- Source info
		source = opts.source or "buffer",
		filepath = opts.filepath,
		bufnr = opts.bufnr,
		version = 0,
		mtime = opts.mtime,

		-- Parsed data
		sections = nil,
		line_map = {},
		section_cache = {}, -- section_id -> section for quick lookup
		metadata = {
			article_names = {},
			tags = {},
		},

		-- Buffer sync
		dirty_ranges = {}, -- Array of DirtyRange objects
		pending_changes = {},
		sync_timer = nil,
		sync_strategy = opts.sync_strategy or SYNC_STRATEGY.IMMEDIATE,

		-- Content cache
		lines = nil,
		line_checksums = {}, -- For detecting actual changes

		-- Statistics
		stats = {
			tasks = 0,
			completed = 0,
			sections = 0,
			parse_time = 0,
			incremental_parses = 0,
			full_parses = 0,
		},

		-- State
		is_parsing = false,
		parse_timer = nil,

		-- Incremental parsing config
		incremental_threshold = opts.incremental_threshold or 100, -- Max lines for incremental
		force_full_parse = false,
	}, self)
end

-- =============================================================================
-- Metadata Parsing (Optimized)
-- =============================================================================

function Document:parse_metadata(lines)
	local stop_timer = Logger.start_timer("document.parse_metadata")

	self.metadata = {
		article_names = {},
		tags = {},
	}

	for i, line in ipairs(lines) do
		local trimmed = parser.trim(line)

		if trimmed == "" then
			stop_timer()
			return i - 1
		end

		local article = trimmed:match(constants.PATTERNS.ARTICLE_TITLE)
		if article then
			table.insert(self.metadata.article_names, parser.trim(article))
		end

		if trimmed:match(constants.PATTERNS.TAG_LINE) then
			for tag in trimmed:gmatch("@(%w+)") do
				if not vim.tbl_contains(self.metadata.tags, tag) then
					table.insert(self.metadata.tags, tag)
				end
			end
		end

		if i > 20 then
			break
		end
	end

	stop_timer()
	return #lines
end

-- =============================================================================
-- Line Checksum for Change Detection
-- =============================================================================

local function compute_line_checksum(line)
	-- Simple hash for change detection
	local hash = 0
	for i = 1, #line do
		hash = (hash * 31 + line:byte(i)) % 2147483647
	end
	return hash
end

function Document:_update_line_checksums(start_line, end_line)
	start_line = start_line or 1
	end_line = end_line or #self.lines

	for i = start_line, end_line do
		if self.lines[i] then
			self.line_checksums[i] = compute_line_checksum(self.lines[i])
		else
			self.line_checksums[i] = nil
		end
	end
end

function Document:_has_line_changed(line_num, new_content)
	local old_checksum = self.line_checksums[line_num]
	local new_checksum = compute_line_checksum(new_content)
	return old_checksum ~= new_checksum
end

-- =============================================================================
-- Full Document Parsing
-- =============================================================================

function Document:parse_full(lines)
	local start_time = vim.loop.hrtime()
	self.is_parsing = true
	self.lines = lines

	-- Update checksums
	self:_update_line_checksums()

	-- Parse metadata first
	local metadata_end = self:parse_metadata(lines)

	-- Initialize section builder
	local builder = Section.SectionTreeBuilder:new()
	local code_tracker = parser.CodeBlockTracker:new()

	-- Set root metadata
	if #self.metadata.article_names > 0 then
		builder.root.text = self.metadata.article_names[1]
	end

	-- Parse document body
	local body_start = metadata_end + 1
	if body_start <= #lines then
		for i = 1, body_start - 1 do
			code_tracker:update(lines[i])
		end

		for line_num = body_start, #lines do
			local line = lines[line_num]
			builder:update_current_end(line_num)
			local in_code_block = code_tracker:update(line)

			if not in_code_block then
				local section_type = parser.detect_section_type(line, in_code_block)

				if section_type ~= "article" and section_type ~= "tag" then
					local section = Section.create_from_line(line, line_num, in_code_block)
					if section then
						builder:add_section(section)
					end
				end

				local is_task, is_completed = parser.is_task_line(line)
				if is_task then
					local task_text = parser.get_task_text(line)
					local task_attrs = parser.parse_attributes(line, require("zortex.utils.attributes").schemas.task)

					local task = {
						line = line_num,
						text = task_text,
						completed = is_completed,
						attributes = task_attrs,
					}

					local current = builder.stack[#builder.stack] or builder.root
					table.insert(current.tasks, task)
				end
			end
		end
	end

	-- Finalize tree
	self.sections = builder:get_tree()
	self.sections.end_line = #lines

	-- Build caches
	self:_build_line_map()
	self:_build_section_cache()

	-- Update statistics
	self:update_stats()
	self.stats.full_parses = self.stats.full_parses + 1

	self.version = self.version + 1
	self.is_parsing = false
	self.dirty_ranges = {}
	self.pending_changes = {}
	self.force_full_parse = false

	local parse_time = (vim.loop.hrtime() - start_time) / 1e6
	self.stats.parse_time = parse_time

	Events.emit("document:parsed", {
		document = self,
		parse_time = parse_time,
		full_parse = true,
	})
end

-- =============================================================================
-- Incremental Parsing
-- =============================================================================

function Document:parse_incremental(lines)
	if not self.sections or self.force_full_parse then
		return self:parse_full(lines)
	end

	-- Merge overlapping dirty ranges
	self:_merge_dirty_ranges()

	-- Check if changes are too extensive
	local total_dirty_lines = 0
	for _, range in ipairs(self.dirty_ranges) do
		total_dirty_lines = total_dirty_lines + (range.end_line - range.start_line + 1)
	end

	if total_dirty_lines > self.incremental_threshold or #self.dirty_ranges > 10 then
		Logger.info("document", "Too many changes, falling back to full parse", {
			dirty_lines = total_dirty_lines,
			ranges = #self.dirty_ranges,
		})
		return self:parse_full(lines)
	end

	local start_time = vim.loop.hrtime()
	self.is_parsing = true
	self.lines = lines

	-- Process each dirty range
	for _, range in ipairs(self.dirty_ranges) do
		self:_process_dirty_range(range, lines)
	end

	-- Rebuild caches
	self:_build_line_map()
	self:_build_section_cache()

	-- Update statistics
	self:update_stats()
	self.stats.incremental_parses = self.stats.incremental_parses + 1

	self.version = self.version + 1
	self.is_parsing = false
	self.dirty_ranges = {}

	local parse_time = (vim.loop.hrtime() - start_time) / 1e6
	self.stats.parse_time = parse_time

	Events.emit("document:parsed", {
		document = self,
		parse_time = parse_time,
		full_parse = false,
		incremental = true,
	})
end

function Document:_process_dirty_range(range, lines)
	local stop_timer = Logger.start_timer("document.process_dirty_range")

	-- Find affected sections
	local affected_sections = self:_find_affected_sections(range)

	if #affected_sections == 0 then
		stop_timer()
		return
	end

	-- Determine reparse boundaries
	local reparse_start = math.huge
	local reparse_end = 0

	for _, section in ipairs(affected_sections) do
		reparse_start = math.min(reparse_start, section.start_line)
		reparse_end = math.max(reparse_end, section.end_line)
	end

	-- Adjust for line delta
	if range.line_delta ~= 0 then
		self:_shift_sections(reparse_end + 1, range.line_delta)
	end

	-- Reparse the affected region
	self:_reparse_region(reparse_start, reparse_end + range.line_delta, lines)

	-- Update line checksums for changed region
	self:_update_line_checksums(range.start_line, range.end_line + range.line_delta)

	stop_timer({
		range = range,
		affected_sections = #affected_sections,
		reparse_lines = reparse_end - reparse_start + 1,
	})
end

function Document:_find_affected_sections(range)
	local affected = {}
	local seen = {}

	local function check_section(section)
		-- Check if section overlaps with dirty range
		if section.start_line <= range.end_line and section.end_line >= range.start_line then
			if not seen[section] then
				seen[section] = true
				table.insert(affected, section)
			end
		end

		for _, child in ipairs(section.children) do
			check_section(child)
		end
	end

	check_section(self.sections)
	return affected
end

function Document:_shift_sections(from_line, delta)
	if delta == 0 then
		return
	end

	local function shift_section(section)
		if section.start_line >= from_line then
			section.start_line = section.start_line + delta
			section.end_line = section.end_line + delta

			-- Shift tasks
			for _, task in ipairs(section.tasks) do
				if task.line >= from_line then
					task.line = task.line + delta
				end
			end
		elseif section.end_line >= from_line then
			-- Section spans the boundary
			section.end_line = section.end_line + delta
		end

		for _, child in ipairs(section.children) do
			shift_section(child)
		end
	end

	shift_section(self.sections)
end

function Document:_reparse_region(start_line, end_line, lines)
	local stop_timer = Logger.start_timer("document.reparse_region")

	-- Find the parent section that contains this region
	local parent_section = self:_find_smallest_containing_section(start_line, end_line)
	if not parent_section then
		parent_section = self.sections
	end

	-- Remove old children in this range
	local new_children = {}
	for _, child in ipairs(parent_section.children) do
		if child.start_line < start_line or child.start_line > end_line then
			table.insert(new_children, child)
		end
	end
	parent_section.children = new_children

	-- Clear old tasks in range
	local new_tasks = {}
	for _, task in ipairs(parent_section.tasks) do
		if task.line < start_line or task.line > end_line then
			table.insert(new_tasks, task)
		end
	end
	parent_section.tasks = new_tasks

	-- Reparse the region
	local code_tracker = parser.CodeBlockTracker:new()

	-- Sync code tracker state up to start_line
	for i = 1, start_line - 1 do
		if lines[i] then
			code_tracker:update(lines[i])
		end
	end

	-- Parse lines in the region
	local current_parent = parent_section
	local section_stack = { parent_section }

	for line_num = start_line, math.min(end_line, #lines) do
		local line = lines[line_num]
		if line then
			local in_code_block = code_tracker:update(line)

			if not in_code_block then
				local section_type = parser.detect_section_type(line, in_code_block)

				if section_type ~= "article" and section_type ~= "tag" and section_type ~= "text" then
					local section = Section.create_from_line(line, line_num, in_code_block)
					if section then
						-- Find appropriate parent
						while #section_stack > 1 do
							local potential_parent = section_stack[#section_stack]
							if potential_parent:can_contain(section) then
								potential_parent:add_child(section)
								table.insert(section_stack, section)
								current_parent = section
								break
							else
								table.remove(section_stack)
								current_parent = section_stack[#section_stack]
							end
						end

						-- If no parent found, add to root parent
						if section.parent == nil then
							parent_section:add_child(section)
							section_stack = { parent_section, section }
							current_parent = section
						end
					end
				end

				-- Parse tasks
				local is_task, is_completed = parser.is_task_line(line)
				if is_task then
					local task_text = parser.get_task_text(line)
					local task_attrs = parser.parse_attributes(line, require("zortex.utils.attributes").schemas.task)

					local task = {
						line = line_num,
						text = task_text,
						completed = is_completed,
						attributes = task_attrs,
					}

					table.insert(current_parent.tasks, task)
				end
			end

			-- Update section end lines
			for _, section in ipairs(section_stack) do
				section.end_line = math.max(section.end_line, line_num)
			end
		end
	end

	stop_timer({
		start_line = start_line,
		end_line = end_line,
		lines_parsed = end_line - start_line + 1,
	})
end

function Document:_find_smallest_containing_section(start_line, end_line)
	local smallest = nil
	local smallest_size = math.huge

	local function check_section(section)
		if section.start_line <= start_line and section.end_line >= end_line then
			local size = section.end_line - section.start_line
			if size < smallest_size then
				smallest = section
				smallest_size = size
			end
		end

		for _, child in ipairs(section.children) do
			check_section(child)
		end
	end

	if self.sections then
		check_section(self.sections)
	end

	return smallest
end

-- =============================================================================
-- Dirty Range Management
-- =============================================================================

function Document:_mark_dirty(start_line, end_line, change_type, line_delta)
	local range = DirtyRange:new(start_line, end_line, change_type or CHANGE_TYPE.MODIFY, line_delta or 0)
	table.insert(self.dirty_ranges, range)

	Logger.debug("document", "Marked dirty", {
		range = range,
		total_ranges = #self.dirty_ranges,
	})
end

function Document:_merge_dirty_ranges()
	if #self.dirty_ranges <= 1 then
		return
	end

	-- Sort by start line
	table.sort(self.dirty_ranges, function(a, b)
		return a.start_line < b.start_line
	end)

	-- Merge overlapping or adjacent ranges
	local merged = {}
	local current = self.dirty_ranges[1]

	for i = 2, #self.dirty_ranges do
		local next = self.dirty_ranges[i]

		-- Check if ranges overlap or are adjacent
		if current.end_line >= next.start_line - 1 then
			current:merge(next)
		else
			table.insert(merged, current)
			current = next
		end
	end

	table.insert(merged, current)
	self.dirty_ranges = merged
end

-- =============================================================================
-- Cache Building
-- =============================================================================

function Document:_build_line_map()
	self.line_map = {}

	local function map_lines(section)
		for line = section.start_line, section.end_line do
			local existing = self.line_map[line]
			if not existing or #section:get_path() > #existing:get_path() then
				self.line_map[line] = section
			end
		end
		for _, child in ipairs(section.children) do
			map_lines(child)
		end
	end

	if self.sections then
		map_lines(self.sections)
	end
end

function Document:_build_section_cache()
	self.section_cache = {}

	local function cache_section(section)
		local id = section:get_id()
		self.section_cache[id] = section

		for _, child in ipairs(section.children) do
			cache_section(child)
		end
	end

	if self.sections then
		cache_section(self.sections)
	end
end

-- =============================================================================
-- Buffer Operations with Change Tracking
-- =============================================================================

function Document:update_line(lnum, new_text)
	if self.source ~= "buffer" or not self.bufnr then
		return false
	end

	-- Check if line actually changed
	if self.lines and self.lines[lnum] then
		if not self:_has_line_changed(lnum, new_text) then
			return true -- No actual change
		end
	end

	table.insert(self.pending_changes, {
		type = "update_line",
		lnum = lnum,
		text = new_text,
	})

	self:_mark_dirty(lnum, lnum, CHANGE_TYPE.MODIFY, 0)
	self:_schedule_sync()
	return true
end

function Document:insert_lines(lnum, lines)
	if self.source ~= "buffer" or not self.bufnr then
		return false
	end

	table.insert(self.pending_changes, {
		type = "insert_lines",
		lnum = lnum,
		lines = lines,
	})

	self:_mark_dirty(lnum, lnum + #lines - 1, CHANGE_TYPE.INSERT, #lines)
	self:_schedule_sync()
	return true
end

function Document:delete_lines(start_lnum, end_lnum)
	if self.source ~= "buffer" or not self.bufnr then
		return false
	end

	local num_deleted = end_lnum - start_lnum + 1

	table.insert(self.pending_changes, {
		type = "delete_lines",
		start_lnum = start_lnum,
		end_lnum = end_lnum,
	})

	self:_mark_dirty(start_lnum, start_lnum, CHANGE_TYPE.DELETE, -num_deleted)
	self:_schedule_sync()
	return true
end

function Document:replace_lines(start_lnum, end_lnum, new_lines)
	if self.source ~= "buffer" or not self.bufnr then
		return false
	end

	local old_count = end_lnum - start_lnum + 1
	local new_count = #new_lines
	local line_delta = new_count - old_count

	table.insert(self.pending_changes, {
		type = "replace_lines",
		start_lnum = start_lnum,
		end_lnum = end_lnum,
		lines = new_lines,
	})

	local change_type = CHANGE_TYPE.MODIFY
	if line_delta > 0 then
		change_type = CHANGE_TYPE.INSERT
	elseif line_delta < 0 then
		change_type = CHANGE_TYPE.DELETE
	end

	self:_mark_dirty(start_lnum, start_lnum + new_count - 1, change_type, line_delta)
	self:_schedule_sync()
	return true
end

-- =============================================================================
-- Sync Management
-- =============================================================================

function Document:_schedule_sync()
	if self.sync_strategy == SYNC_STRATEGY.IMMEDIATE then
		self:_apply_changes()
	elseif self.sync_strategy == SYNC_STRATEGY.BATCHED then
		if self.sync_timer then
			vim.fn.timer_stop(self.sync_timer)
		end

		local batch_delay = Config.core.buffer_sync.batch_delay or 500
		self.sync_timer = vim.fn.timer_start(batch_delay, function()
			vim.schedule(function()
				self:_apply_changes()
			end)
		end)

		local max_batch = Config.core.buffer_sync.max_batch_size or 50
		if #self.pending_changes >= max_batch then
			Logger.warn("document", "Forcing sync due to large batch", {
				bufnr = self.bufnr,
				size = #self.pending_changes,
			})
			self:_apply_changes()
		end
	end
end

function Document:_apply_changes()
	if #self.pending_changes == 0 then
		return
	end

	local stop_timer = Logger.start_timer("document.apply_changes")

	-- Apply buffer changes
	for _, change in ipairs(self.pending_changes) do
		local ok, err = pcall(function()
			if change.type == "update_line" then
				vim.api.nvim_buf_set_lines(self.bufnr, change.lnum - 1, change.lnum, false, { change.text })
			elseif change.type == "insert_lines" then
				vim.api.nvim_buf_set_lines(self.bufnr, change.lnum - 1, change.lnum - 1, false, change.lines)
			elseif change.type == "delete_lines" then
				vim.api.nvim_buf_set_lines(self.bufnr, change.start_lnum - 1, change.end_lnum, false, {})
			elseif change.type == "replace_lines" then
				vim.api.nvim_buf_set_lines(self.bufnr, change.start_lnum - 1, change.end_lnum, false, change.lines)
			end
		end)

		if not ok then
			Logger.error("document", "Failed to apply change", {
				change_type = change.type,
				error = err,
			})
		end
	end

	local change_count = #self.pending_changes
	self.pending_changes = {}

	if self.sync_timer then
		vim.fn.timer_stop(self.sync_timer)
		self.sync_timer = nil
	end

	stop_timer({ change_count = change_count })

	-- Schedule reparse if we have dirty ranges
	if #self.dirty_ranges > 0 then
		self:_schedule_reparse()
	end

	Events.emit("document:synced", {
		bufnr = self.bufnr,
		document = self,
		change_count = change_count,
	})
end

function Document:_schedule_reparse()
	if self.parse_timer then
		vim.fn.timer_stop(self.parse_timer)
	end

	self.parse_timer = vim.fn.timer_start(100, function()
		vim.schedule(function()
			if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
				local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
				self:parse_incremental(lines)
			end
		end)
	end)
end

function Document:sync()
	self:_apply_changes()
end

-- =============================================================================
-- Statistics
-- =============================================================================

function Document:update_stats()
	self.stats.tasks = 0
	self.stats.completed = 0
	self.stats.sections = 0

	local function count(section)
		self.stats.sections = self.stats.sections + 1
		for _, task in ipairs(section.tasks) do
			self.stats.tasks = self.stats.tasks + 1
			if task.completed then
				self.stats.completed = self.stats.completed + 1
			end
		end
		for _, child in ipairs(section.children) do
			count(child)
		end
	end

	if self.sections then
		count(self.sections)
		self.stats.sections = self.stats.sections - 1
	end
end

-- =============================================================================
-- Query Methods
-- =============================================================================

function Document:get_section_at_line(line_num)
	return self.line_map[line_num]
end

function Document:get_section_by_id(section_id)
	return self.section_cache[section_id]
end

function Document:get_task(task_id)
	if not self.sections then
		return nil
	end

	local function find_task(section)
		for _, task in ipairs(section.tasks) do
			if task.attributes.id == task_id then
				return task, section
			end
		end
		for _, child in ipairs(section.children) do
			local found, found_section = find_task(child)
			if found then
				return found, found_section
			end
		end
	end

	return find_task(self.sections)
end

function Document:get_all_tasks()
	if not self.sections then
		return {}
	end
	return self.sections:get_all_tasks()
end

function Document:get_article_name()
	return self.metadata.article_names[1] or ""
end

function Document:get_metadata()
	return vim.tbl_deep_extend("force", {}, self.metadata)
end

function Document:get_stats()
	return vim.tbl_deep_extend("force", {}, self.stats)
end

-- =============================================================================
-- Document Manager Singleton
-- =============================================================================

local Manager = {
	buffers = {},
	files = {},
	lru = LRU:new({ max_items = 20 }),
	reparse_timers = {},
	config = {},
}

-- =============================================================================
-- Document Loading
-- =============================================================================

function Manager:get_buffer(bufnr, filepath)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	filepath = filepath or vim.api.nvim_buf_get_name(bufnr)

	if self.buffers[bufnr] then
		return self.buffers[bufnr]
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local doc = Document:new({
		source = "buffer",
		bufnr = bufnr,
		filepath = filepath,
		sync_strategy = cfg.sync_strategy,
		incremental_threshold = cfg.incremental_threshold,
	})

	doc:parse_full(lines)
	self.buffers[bufnr] = doc

	Events.emit("document:loaded", {
		bufnr = bufnr,
		filepath = filepath,
		document = doc,
	})

	return doc
end

function Manager:get_file(filepath)
	if filepath:sub(1, 1) ~= "/" then
		filepath = fs.get_file_path(filepath)
	end

	local cached = self.lru:get(filepath)
	if cached then
		return cached
	end

	for bufnr, doc in pairs(self.buffers) do
		if doc.filepath == filepath then
			return doc
		end
	end

	local lines = fs.read_lines(filepath)
	if not lines then
		return nil
	end

	local stat = vim.loop.fs_stat(filepath)
	local doc = Document:new({
		source = "file",
		filepath = filepath,
		mtime = stat and stat.mtime.sec,
	})

	doc:parse_full(lines)

	self.lru:set(filepath, doc)
	self.files[filepath] = doc

	Events.emit("document:loaded", {
		filepath = filepath,
		document = doc,
	})

	return doc
end

function Manager:get_current()
	return self:get_buffer(vim.api.nvim_get_current_buf())
end

-- =============================================================================
-- External Change Tracking (for TextChanged events)
-- =============================================================================

function Manager:mark_buffer_dirty(bufnr, start_line, end_line)
	local doc = self.buffers[bufnr]
	if not doc then
		return
	end

	-- Estimate change type and line delta
	local current_line_count = vim.api.nvim_buf_line_count(bufnr)
	local old_line_count = doc.lines and #doc.lines or current_line_count
	local line_delta = current_line_count - old_line_count

	local change_type = CHANGE_TYPE.MODIFY
	if line_delta > 0 then
		change_type = CHANGE_TYPE.INSERT
	elseif line_delta < 0 then
		change_type = CHANGE_TYPE.DELETE
	end

	doc:_mark_dirty(start_line, end_line, change_type, line_delta)

	-- Schedule reparse
	if self.reparse_timers[bufnr] then
		vim.fn.timer_stop(self.reparse_timers[bufnr])
	end

	self.reparse_timers[bufnr] = vim.fn.timer_start(300, function()
		vim.schedule(function()
			self:reparse_buffer(bufnr)
		end)
	end)
end

function Manager:reparse_buffer(bufnr)
	local doc = self.buffers[bufnr]
	if not doc or doc.is_parsing then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	doc:parse_incremental(lines)

	self.reparse_timers[bufnr] = nil
end

-- =============================================================================
-- Document Lifecycle
-- =============================================================================

function Manager:unload_buffer(bufnr)
	local doc = self.buffers[bufnr]
	if not doc then
		return
	end

	doc:sync()

	if self.reparse_timers[bufnr] then
		vim.fn.timer_stop(self.reparse_timers[bufnr])
		self.reparse_timers[bufnr] = nil
	end

	if doc.parse_timer then
		vim.fn.timer_stop(doc.parse_timer)
	end

	self.buffers[bufnr] = nil

	Events.emit("document:unloaded", {
		bufnr = bufnr,
		document = doc,
	})
end

function Manager:reload_file(filepath)
	local doc = self.files[filepath]
	if not doc then
		return
	end

	local stat = vim.loop.fs_stat(filepath)
	if stat and stat.mtime.sec > (doc.mtime or 0) then
		self.files[filepath] = nil
		self.lru:set(filepath, nil)
		return self:get_file(filepath)
	end

	return doc
end

-- =============================================================================
-- Utility Methods
-- =============================================================================

function Manager:get_all_documents()
	local docs = {}

	for _, doc in pairs(self.buffers) do
		table.insert(docs, doc)
	end

	for filepath, doc in pairs(self.files) do
		local in_buffer = false
		for _, bdoc in pairs(self.buffers) do
			if bdoc.filepath == filepath then
				in_buffer = true
				break
			end
		end
		if not in_buffer then
			table.insert(docs, doc)
		end
	end

	return docs
end

function Manager:sync_all()
	for _, doc in pairs(self.buffers) do
		doc:sync()
	end
end

function Manager:force_full_parse(bufnr)
	local doc = self.buffers[bufnr or vim.api.nvim_get_current_buf()]
	if doc then
		doc.force_full_parse = true
		self:reparse_buffer(doc.bufnr)
	end
end

-- =============================================================================
-- Setup
-- =============================================================================

function Manager:setup_autocmds()
	local group = vim.api.nvim_create_augroup("ZortexDoc", { clear = true })
	local extensions = { "*" .. Config.extension }

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = group,
		pattern = extensions,
		callback = function(args)
			self:get_buffer(args.buf, args.file)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = extensions,
		callback = vim.schedule_wrap(function(args)
			local start_line = 1
			local end_line = -1
			if args.data then
				start_line = args.data.firstline or start_line
				end_line = args.data.lastline or end_line
			end
			self:mark_buffer_dirty(args.buf, start_line, end_line)
		end),
	})

	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		pattern = extensions,
		callback = function(args)
			local doc = self.buffers[args.buf]
			if doc and doc.sync_strategy == SYNC_STRATEGY.ON_SAVE then
				doc:sync()
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = extensions,
		callback = function(args)
			local doc = self.buffers[args.buf]
			if doc then
				local stat = vim.loop.fs_stat(args.file)
				if stat then
					doc.mtime = stat.mtime.sec
				end
				Events.emit("document:saved", {
					bufnr = args.buf,
					filepath = args.file,
					document = doc,
				})
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		pattern = extensions,
		callback = function(args)
			self:unload_buffer(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			self:sync_all()
		end,
	})
end

function Manager:setup(opts)
	cfg = opts or {}
	self:setup_autocmds()
end

-- =============================================================================
-- Module Exports
-- =============================================================================

M._manager = Manager
M.Document = Document
M.SYNC_STRATEGY = SYNC_STRATEGY
M.CHANGE_TYPE = CHANGE_TYPE

-- Public API
function M.setup(opts)
	return M._manager:setup(opts)
end

function M.get_buffer(bufnr)
	return M._manager:get_buffer(bufnr)
end

function M.get_file(filepath)
	return M._manager:get_file(filepath)
end

function M.get_current()
	return M._manager:get_current()
end

function M.get_all_documents()
	return M._manager:get_all_documents()
end

function M.mark_buffer_dirty(bufnr, start_line, end_line)
	return M._manager:mark_buffer_dirty(bufnr, start_line, end_line)
end

function M.sync_all()
	return M._manager:sync_all()
end

function M.force_full_parse(bufnr)
	return M._manager:force_full_parse(bufnr)
end

-- Status for debugging
function M.get_status()
	local status = {
		buffers = vim.tbl_count(M._manager.buffers),
		files = vim.tbl_count(M._manager.files),
		pending_changes = 0,
		dirty_documents = 0,
		total_incremental_parses = 0,
		total_full_parses = 0,
	}

	for _, doc in pairs(M._manager.buffers) do
		status.pending_changes = status.pending_changes + #doc.pending_changes
		if #doc.dirty_ranges > 0 then
			status.dirty_documents = status.dirty_documents + 1
		end
		status.total_incremental_parses = status.total_incremental_parses + doc.stats.incremental_parses
		status.total_full_parses = status.total_full_parses + doc.stats.full_parses
	end

	return status
end

return M
