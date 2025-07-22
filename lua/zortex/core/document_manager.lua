-- core/document_manager.lua
-- Document cache and parsing with buffer integration
local M = {}

local EventBus = require("zortex.core.event_bus")
local Section = require("zortex.core.section")
local parser = require("zortex.core.parser")
local attributes = require("zortex.core.attributes")
local constants = require("zortex.constants")

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
      EventBus.emit("document:evicted", { filepath = evicted_key })
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
    sections = nil,      -- Section tree root
    line_map = {},       -- line_num -> deepest section
    dirty_ranges = {},   -- { {start, end}, ... }
    
    -- Metadata
    article_name = "",
    tags = {},
    
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
  
  -- Build section tree
  local builder = Section.SectionTreeBuilder:new()
  self.line_map = {}
  
  for line_num, line in ipairs(lines) do
    -- Update current section end
    builder:update_current_end(line_num)
    
    -- Create section if this line starts one
    local section = Section.create_from_line(line, line_num)
    if section then
      builder:add_section(section)
    end
    
    -- Parse tasks
    local is_task, is_completed = parser.is_task_line(line)
    if is_task then
      local task_text = parser.get_task_text(line)
      local task_attrs = attributes.parse_task_attributes(line)
      
      local task = {
        line = line_num,
        text = task_text,
        completed = is_completed,
        attributes = task_attrs,
      }
      
      -- Add to current section
      local current = builder.stack[#builder.stack] or builder.root
      table.insert(current.tasks, task)
    end
    
    -- Extract article name from first article title
    if line_num <= 10 and self.article_name == "" then
      local name = parser.extract_article_name(line)
      if name then
        self.article_name = name
      end
    end
  end
  
  -- Finalize tree
  self.sections = builder:get_tree()
  self.sections.end_line = #lines
  
  -- Build line map (line -> deepest section)
  local function map_lines(section)
    for line = section.start_line, section.end_line do
      -- Only update if this section is deeper
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
  
  -- Extract tags
  self.tags = parser.extract_tags_from_lines(lines, 15)
  
  -- Update statistics
  self:update_stats()
  
  self.version = self.version + 1
  self.is_parsing = false
  self.dirty_ranges = {}
  
  local parse_time = (vim.loop.hrtime() - start_time) / 1e6
  self.stats.parse_time = parse_time
  
  EventBus.emit("document:parsed", {
    document = self,
    parse_time = parse_time,
    full_parse = true,
  })
end

-- Incremental parsing for dirty ranges
function Document:parse_incremental(lines)
  if #self.dirty_ranges == 0 then return end
  
  local start_time = vim.loop.hrtime()
  self.is_parsing = true
  
  -- TODO: Implement incremental parsing
  -- For now, fall back to full parse
  self:parse_full(lines)
  
  self.is_parsing = false
  
  local parse_time = (vim.loop.hrtime() - start_time) / 1e6
  
  EventBus.emit("document:parsed", {
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
  
  local function count_sections(section)
    self.stats.sections = self.stats.sections + 1
    local tasks = section:get_all_tasks()
    self.stats.tasks = self.stats.tasks + #tasks
    for _, task in ipairs(tasks) do
      if task.completed then
        self.stats.completed = self.stats.completed + 1
      end
    end
  end
  
  if self.sections then
    for _, child in ipairs(self.sections.children) do
      count_sections(child)
    end
  end
end

-- Get section at line
function Document:get_section_at_line(line_num)
  return self.line_map[line_num]
end

-- Get task by ID
function Document:get_task(task_id)
  if not self.sections then return nil end
  
  local function find_task(section)
    for _, task in ipairs(section.tasks) do
      if task.attributes.id == task_id then
        return task, section
      end
    end
    for _, child in ipairs(section.children) do
      local found, found_section = find_task(child)
      if found then return found, found_section end
    end
    return nil
  end
  
  return find_task(self.sections)
end

-- Update task
function Document:update_task(task_id, updates)
  local task, section = self:get_task(task_id)
  if not task then return false end
  
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
  if not self.sections then return {} end
  return self.sections:get_all_tasks()
end

-- DocumentManager singleton
local DocumentManager = {
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
function DocumentManager:load_buffer(bufnr, filepath)
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
  
  EventBus.emit("document:loaded", {
    bufnr = bufnr,
    filepath = filepath,
    document = doc,
  })
  
  return doc
end

-- Load document from file
function DocumentManager:load_file(filepath)
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
  local fs = require("zortex.core.filesystem")
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
  
  EventBus.emit("document:loaded", {
    filepath = filepath,
    document = doc,
  })
  
  return doc
end

-- Get document for buffer
function DocumentManager:get_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return self.buffers[bufnr]
end

-- Get document for file
function DocumentManager:get_file(filepath)
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
function DocumentManager:mark_buffer_dirty(bufnr, start_line, end_line)
  local doc = self.buffers[bufnr]
  if not doc then return end
  
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
function DocumentManager:reparse_buffer(bufnr)
  local doc = self.buffers[bufnr]
  if not doc or doc.is_parsing then return end
  
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  if #doc.dirty_ranges > 5 or not doc.sections then
    -- Too many changes, do full parse
    doc:parse_full(lines)
  else
    -- Incremental parse
    doc:parse_incremental(lines)
  end
  
  EventBus.emit("document:changed", {
    bufnr = bufnr,
    document = doc,
    dirty_ranges = doc.dirty_ranges,
  })
  
  doc.dirty_ranges = {}
  self.reparse_timers[bufnr] = nil
end

-- Unload buffer document
function DocumentManager:unload_buffer(bufnr)
  local doc = self.buffers[bufnr]
  if not doc then return end
  
  -- Cancel reparse timer
  if self.reparse_timers[bufnr] then
    vim.fn.timer_stop(self.reparse_timers[bufnr])
    self.reparse_timers[bufnr] = nil
  end
  
  self.buffers[bufnr] = nil
  
  EventBus.emit("document:unloaded", {
    bufnr = bufnr,
    document = doc,
  })
end

-- Reload file document (if file changed)
function DocumentManager:reload_file(filepath)
  local doc = self.files[filepath]
  if not doc then return end
  
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
function DocumentManager:get_all_documents()
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

-- Setup autocmds
function DocumentManager:setup_autocmds()
  local group = vim.api.nvim_create_augroup("ZortexDocumentManager", { clear = true })
  
  -- Load buffer on read
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = { "*.zortex", "*.md", "*.txt" },
    callback = function(args)
      self:load_buffer(args.buf, args.file)
    end,
  })
  
  -- Mark dirty on change
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = { "*.zortex", "*.md", "*.txt" },
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
    pattern = { "*.zortex", "*.md", "*.txt" },
    callback = function(args)
      self:unload_buffer(args.buf)
    end,
  })
  
  -- Save file mtime on write
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.zortex", "*.md", "*.txt" },
    callback = function(args)
      local doc = self.buffers[args.buf]
      if doc then
        local stat = vim.loop.fs_stat(args.file)
        if stat then
          doc.mtime = stat.mtime.sec
        end
        EventBus.emit("document:saved", {
          bufnr = args.buf,
          filepath = args.file,
          document = doc,
        })
      end
    end,
  })
end

-- Initialize
function DocumentManager:init()
  self:setup_autocmds()
end

-- Export singleton
M._instance = DocumentManager

-- Public API
function M.init()
  return M._instance:init()
end

function M.get_buffer(bufnr)
  return M._instance:get_buffer(bufnr)
end

function M.get_file(filepath)
  return M._instance:get_file(filepath)
end

function M.get_all_documents()
  return M._instance:get_all_documents()
end

function M.mark_buffer_dirty(bufnr, start_line, end_line)
  return M._instance:mark_buffer_dirty(bufnr, start_line, end_line)
end

return M