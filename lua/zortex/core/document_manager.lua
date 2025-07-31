-- core/document_manager.lua - Document cache and parsing with buffer integration
local M = {}

local Events = require("zortex.core.event_bus")
local Section = require("zortex.core.section")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local Config = require("zortex.config")
local constants = require("zortex.constants")
local attributes = require("zortex.utils.attributes")

-- LRU Cache implementation
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
		-- Move to front
		self:_touch(key)
	end
	return item
end

function LRU:set(key, value)
	if self.items[key] then
		-- Update existing
		self.items[key] = value
		self:_touch(key)
	else
		-- Add new
		table.insert(self.order, 1, key)
		self.items[key] = value

		-- Evict if needed
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

-- Document class
local Document = {}
Document.__index = Document

function Document:new(opts)
	return setmetatable({
		source = opts.source or "buffer", -- "buffer" or "file"
		filepath = opts.filepath,
		bufnr = opts.bufnr,
		version = 0,
		mtime = opts.mtime,

		-- Parsed data
		sections = nil, -- Section tree root
		line_map = {}, -- line_num -> deepest section
		dirty_ranges = {}, -- { {start, end}, ... }

		-- Metadata
		article_names = {}, -- Array of all article names (@@)
		tags = {},
		lines = nil, -- Store lines for searching

		-- Statistics
		stats = {
			tasks = 0,
			completed = 0,
			sections = 0,
			parse_time = 0,
		},

		-- Parsing state
		is_parsing = false,
		parse_timer = nil,
	}, self)
end

-- Parse entire document
function Document:parse_full(lines)
	local start_time = vim.loop.hrtime()
	self.is_parsing = true

	self.lines = lines
	self.article_names = {}
	self.tags = {}
	self.line_map = {}

	local builder = Section.SectionTreeBuilder:new()
	local code_tracker = parser.CodeBlockTracker:new()

	-- 1. Parse Metadata Header
	local metadata_end_line = 0
	for i, line in ipairs(lines) do
		local trimmed_line = parser.trim(line)
		if trimmed_line:match(constants.PATTERNS.ARTICLE_TITLE) then
			local name = parser.extract_article_name(trimmed_line)
			if name then
				table.insert(self.article_names, name)
			end
		elseif trimmed_line:match(constants.PATTERNS.TAG_LINE) then
			for tag in trimmed_line:gmatch("@(%w+)") do
				if not vim.tbl_contains(self.tags, tag) then
					table.insert(self.tags, tag)
				end
			end
		elseif trimmed_line == "" then
			-- Continue past empty lines in metadata header
		else
			-- First non-metadata line, header is done
			metadata_end_line = i - 1
			break
		end
		-- If loop finishes, the whole file was metadata
		if i == #lines then
			metadata_end_line = #lines
		end
	end

	-- Set metadata on the document's root section
	if #self.article_names > 0 then
		builder.root.text = self.article_names[1] -- Use first as primary name
	end

	-- 2. Parse Document Body
	local body_start_line = metadata_end_line + 1
	if body_start_line <= #lines then
		-- Reset and run code tracker up to the start of the body
		code_tracker = parser.CodeBlockTracker:new()
		for i = 1, body_start_line - 1 do
			code_tracker:update(lines[i])
		end

		for line_num = body_start_line, #lines do
			local line = lines[line_num]
			builder:update_current_end(line_num)
			local in_code_block = code_tracker:update(line)

			-- Create section if this line starts one, but ignore metadata lines (@@, @)
			if not in_code_block then
				local section_type = parser.detect_section_type(line, in_code_block)
				if section_type ~= "article" and section_type ~= "tag" then
					local section = Section.create_from_line(line, line_num, in_code_block)
					if section then
						builder:add_section(section)
					end
				end

				-- Parse tasks
				local is_task, is_completed = parser.is_task_line(line)
				if is_task then
					local task_text = parser.get_task_text(line)
					local task_attrs, _ = attributes.parse_task_attributes(line)

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

	-- Build line map (line -> deepest section)
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
	map_lines(self.sections)

	-- Update statistics
	self:update_stats()

	self.version = self.version + 1
	self.is_parsing = false
	self.dirty_ranges = {}

	local parse_time = (vim.loop.hrtime() - start_time) / 1e6
	self.stats.parse_time = parse_time

	Events.emit("document:parsed", {
		document = self,
		parse_time = parse_time,
		full_parse = true,
	})
end

-- Incremental parsing for dirty ranges
function Document:parse_incremental(lines)
	if #self.dirty_ranges == 0 then
		return
	end

	local start_time = vim.loop.hrtime()
	self.is_parsing = true

	-- TODO: Implement incremental parsing
	-- For now, fall back to full parse
	self:parse_full(lines)

	self.is_parsing = false

	local parse_time = (vim.loop.hrtime() - start_time) / 1e6

	Events.emit("document:parsed", {
		document = self,
		parse_time = parse_time,
		full_parse = false,
		ranges = self.dirty_ranges,
	})
end

-- Update document statistics
function Document:update_stats()
	self.stats.tasks = 0
	self.stats.completed = 0
	self.stats.sections = 0

	local function count_sections_and_tasks(section)
		self.stats.sections = self.stats.sections + 1
		for _, task in ipairs(section.tasks) do
			self.stats.tasks = self.stats.tasks + 1
			if task.completed then
				self.stats.completed = self.stats.completed + 1
			end
		end
		for _, child in ipairs(section.children) do
			count_sections_and_tasks(child)
		end
	end

	if self.sections then
		count_sections_and_tasks(self.sections)
		-- Subtract the root section from the count
		self.stats.sections = self.stats.sections - 1
	end
end

-- Get section at line
function Document:get_section_at_line(line_num)
	return self.line_map[line_num]
end

-- Get task by ID
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
		return nil
	end

	return find_task(self.sections)
end

-- Update task
function Document:update_task(task_id, updates)
	local task, section = self:get_task(task_id)
	if not task then
		return false
	end

	-- Apply updates
	for key, value in pairs(updates) do
		task[key] = value
	end

	-- Mark line as dirty for buffer sync
	table.insert(self.dirty_ranges, { task.line, task.line })

	return true
end

-- Get all tasks
function Document:get_all_tasks()
	if not self.sections then
		return {}
	end
	return self.sections:get_all_tasks()
end

-- Get primary article name (for compatibility)
function Document:get_article_name()
	return self.article_names[1] or ""
end

-- Doc singleton
local Doc = {
	-- Buffer documents (source of truth when buffer exists)
	buffers = {},

	-- File documents (lazy loaded, used when no buffer)
	files = {},

	-- LRU for file cache
	lru = LRU:new({ max_items = 20 }),

	-- Reparse timers
	reparse_timers = {},
}

-- Load document from buffer
function Doc:load_buffer(bufnr, filepath)
	if self.buffers[bufnr] then
		return self.buffers[bufnr]
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local doc = Document:new({
		source = "buffer",
		bufnr = bufnr,
		filepath = filepath,
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

-- Load document from file
function Doc:load_file(filepath)
	-- Check if already loaded
	local cached = self.lru:get(filepath)
	if cached then
		return cached
	end

	-- Check if there's a buffer for this file
	for bufnr, doc in pairs(self.buffers) do
		if doc.filepath == filepath then
			return doc
		end
	end

	-- Load from file
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

	-- Cache it
	self.lru:set(filepath, doc)
	self.files[filepath] = doc

	Events.emit("document:loaded", {
		filepath = filepath,
		document = doc,
	})

	return doc
end

-- Get document for buffer
function Doc:get_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return self.buffers[bufnr]
end

-- Get document for file
function Doc:get_file(filepath)
	-- Ensure filepath exists within notes_dir
	if filepath:sub(1, 1) ~= "/" then
		filepath = fs.get_file_path(filepath)
	end

	-- Prefer buffer if available
	for bufnr, doc in pairs(self.buffers) do
		if doc.filepath == filepath then
			return doc
		end
	end

	-- Otherwise load from cache/file
	return self:load_file(filepath)
end

-- Mark buffer dirty
function Doc:mark_buffer_dirty(bufnr, start_line, end_line)
	local doc = self.buffers[bufnr]
	if not doc then
		return
	end

	table.insert(doc.dirty_ranges, { start_line, end_line })

	-- Cancel existing timer
	if self.reparse_timers[bufnr] then
		vim.fn.timer_stop(self.reparse_timers[bufnr])
	end

	-- Schedule reparse
	self.reparse_timers[bufnr] = vim.fn.timer_start(300, function()
		vim.schedule(function()
			self:reparse_buffer(bufnr)
		end)
	end)
end

-- Reparse buffer
function Doc:reparse_buffer(bufnr)
	local doc = self.buffers[bufnr]
	if not doc or doc.is_parsing then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	if #doc.dirty_ranges > 5 or not doc.sections then
		-- Too many changes, do full parse
		doc:parse_full(lines)
	else
		-- Incremental parse
		doc:parse_incremental(lines)
	end

	Events.emit("document:changed", {
		bufnr = bufnr,
		document = doc,
		dirty_ranges = doc.dirty_ranges,
	})

	doc.dirty_ranges = {}
	self.reparse_timers[bufnr] = nil
end

-- Unload buffer document
function Doc:unload_buffer(bufnr)
	local doc = self.buffers[bufnr]
	if not doc then
		return
	end

	-- Cancel reparse timer
	if self.reparse_timers[bufnr] then
		vim.fn.timer_stop(self.reparse_timers[bufnr])
		self.reparse_timers[bufnr] = nil
	end

	self.buffers[bufnr] = nil

	Events.emit("document:unloaded", {
		bufnr = bufnr,
		document = doc,
	})
end

-- Reload file document (if file changed)
function Doc:reload_file(filepath)
	local doc = self.files[filepath]
	if not doc then
		return
	end

	local stat = vim.loop.fs_stat(filepath)
	if stat and stat.mtime.sec > (doc.mtime or 0) then
		-- File changed, reload
		self.files[filepath] = nil
		self.lru:set(filepath, nil)
		return self:load_file(filepath)
	end

	return doc
end

-- Get all loaded documents
function Doc:get_all_documents()
	local docs = {}

	-- Add buffer documents
	for _, doc in pairs(self.buffers) do
		table.insert(docs, doc)
	end

	-- Add file documents not in buffers
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

-- Get a document by filepath without loading into main cache
function Doc:peek_file(filepath)
	-- Check if already in buffers
	for bufnr, doc in pairs(self.buffers) do
		if doc.filepath == filepath then
			return doc
		end
	end

	-- Return nil - let caller handle loading
	return nil
end

-- Setup autocmds
function Doc:setup_autocmds()
	local group = vim.api.nvim_create_augroup("ZortexDoc", { clear = true })
	local extensions = { "*" .. Config.extension }

	-- Load buffer on read
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = group,
		pattern = extensions,
		callback = function(args)
			self:load_buffer(args.buf, args.file)
		end,
	})

	-- Mark dirty on change
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = extensions,
		callback = vim.schedule_wrap(function(args)
			-- Get change range from vim
			local start_line = args.data and args.data.firstline or 1
			local end_line = args.data and args.data.lastline or -1

			self:mark_buffer_dirty(args.buf, start_line, end_line)
		end),
	})

	-- Unload on buffer delete
	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		pattern = extensions,
		callback = function(args)
			self:unload_buffer(args.buf)
		end,
	})

	-- Save file mtime on write
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
end

-- Initialize
function Doc:init()
	self:setup_autocmds()
end

-- Export singleton
M._instance = Doc

-- Public API
function M.init()
	return M._instance:init()
end

function M.get_buffer(bufnr)
	return M._instance:get_buffer(bufnr)
end

function M.load_buffer(bufnr)
	return M._instance:load_buffer(bufnr, vim.api.nvim_buf_get_name(bufnr))
end

function M.get_file(filepath)
	return M._instance:get_file(filepath)
end

function M.get_all_documents()
	return M._instance:get_all_documents()
end

function M.peek_file(filepath)
	return M._instance:peek_file(filepath)
end

function M.mark_buffer_dirty(bufnr, start_line, end_line)
	return M._instance:mark_buffer_dirty(bufnr, start_line, end_line)
end

return M
