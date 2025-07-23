# Zortex Architecture Refactoring Plan

## Executive Summary

The Zortex codebase has evolved into a tightly coupled system where changes in one module cascade unpredictably through others, creating a high cognitive load for developers. The XP system alone touches 12+ files with circular dependencies that make debugging nearly impossible. This refactoring plan transforms Zortex into a **layered, event-driven architecture** that treats sections as first-class citizens and the buffer as the single source of truth.

**Key Outcomes:**

- **50% reduction in module coupling** through event-driven communication
- **Zero UI blocking** via async-first design patterns
- **80% test coverage** enabled by clear service boundaries
- **< 16ms response time** for all user interactions

**Investment:** 8-10 weeks with 2-3 developers
**Risk Level:** Medium (mitigated by incremental migration)

## File & Module Organization

```
lua/zortex/
├── init.lua                    # Setup & public API
├── config.lua                  # User configuration
├── constants.lua               # Shared constants
│
├── core/                       # Foundation layer
│   ├── buffer_sync.lua        # Buffer-Document sync
│   ├── document_manager.lua   # Document cache & parsing
│   ├── event_bus.lua          # Event system
│   ├── logger.lua             # Performance logging
│   ├── parser.lua             # Low-level parsing
│   └── section.lua            # Section model
│
├── services/                   # Business logic layer
│   ├── calendar_service.lua   # Calendar operations
│   ├── notification_service.lua
│   ├── project_service.lua    # Project management
│   ├── search_service.lua     # Search operations
│   ├── task_service.lua       # Task operations
│   └── xp_service.lua         # XP orchestration
│
├── domain/                     # Pure business logic
│   ├── xp/
│   │   ├── calculator.lua     # XP calculations
│   │   ├── distributor.lua    # XP distribution
│   │   └── rules.lua          # Configurable rules
│   ├── task_states.lua        # Task state machine
│   └── date_utils.lua         # Date calculations
│
├── stores/                     # Data persistence
│   ├── base_store.lua         # Store abstraction
│   ├── xp_store.lua           # XP state
│   ├── task_store.lua         # Task state
│   ├── season_store.lua       # Season data
│   └── persistence_manager.lua # Save coordination
│
├── ui/                         # User interface
│   ├── commands.lua           # Vim commands
│   ├── keymaps.lua            # Key bindings
│   ├── calendar_view.lua      # Calendar UI
│   └── telescope/             # Telescope pickers
│
└── features/                   # Feature modules
    ├── highlights.lua         # Syntax highlighting
    ├── completion.lua         # Auto-completion
    └── links.lua              # Link handling
```

## Core Principles

1. **Buffer is Truth**: The Neovim buffer content supersedes file state for all operations
2. **Sections are First-Class**: All features operate on the section tree, not raw text
3. **Async by Default**: Any operation >4ms uses `vim.schedule()` or job control
4. **Events Over Calls**: Modules communicate via EventBus, never direct requires
5. **Fail Fast, Recover Gracefully**: Errors in one module don't cascade
6. **Progressive Enhancement**: Start simple, optimize based on profiling

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                          UI Layer                                │
│         Commands • Keymaps • Telescope • Calendar UI             │
└────────────────────────────┬────────────────────────────────────┘
                             │ Events & Actions
┌────────────────────────────▼────────────────────────────────────┐
│                      Service Layer                               │
│   TaskService • XPService • SearchService • CalendarService     │
│              (Stateless Business Logic)                          │
└────────────────────────────┬────────────────────────────────────┘
                             │ Uses
┌────────────────────────────▼────────────────────────────────────┐
│                    Document Manager                              │
│          Section Cache • Buffer Sync • Tree Management           │
└────────────────────────────┬────────────────────────────────────┘
                             │ Reads/Writes
┌────────────────────────────▼────────────────────────────────────┐
│                     Data Access Layer                            │
│              Repositories • State Stores • Persistence           │
└─────────────────────────────────────────────────────────────────┘

Cross-Cutting: EventBus • Logger • Config • Performance Monitor
```

## Key Components

### 1. DocumentManager

The DocumentManager is the heart of the refactoring, providing a unified interface for all document operations while maintaining buffer-file synchronization.

#### Design Options

**Option 1: Buffer-Centric Cache** ⭐ RECOMMENDED

```lua
-- Maintains AST per buffer, syncs with file on save
DocumentManager = {
  buffers = {}, -- bufnr -> Document
  files = {},   -- filepath -> Document (lazy loaded)
}
```

- ✅ Natural fit for Vim's buffer model
- ✅ Handles unsaved changes perfectly
- ❌ Duplicate data if buffer + file both loaded

**Option 2: Unified Cache**

```lua
-- Single cache, tracks buffer/file state
DocumentManager = {
  documents = {}, -- filepath -> { ast, buffer_version, file_version }
}
```

- ✅ Memory efficient
- ❌ Complex version reconciliation
- ❌ Harder to reason about state

**Option 3: File-Only Cache**

```lua
-- Only caches file content, always parses buffer
DocumentManager = {
  file_cache = {} -- filepath -> AST
}
```

- ✅ Simple implementation
- ❌ Repeated buffer parsing
- ❌ Poor performance

#### Recommended Implementation

```lua
-- core/document_manager.lua
local DocumentManager = {
  -- Buffer documents (source of truth when buffer exists)
  buffers = {}, -- bufnr -> Document

  -- File documents (lazy loaded, used when no buffer)
  files = {},   -- filepath -> Document

  -- LRU for file cache (buffers exempt)
  lru = LRU:new({ max_items = 20 })
}

-- Document structure
Document = {
  source = "buffer|file",
  version = 0,        -- Increments on change
  mtime = nil,        -- File mtime (nil for buffers)

  -- Parsed data
  sections = {},      -- Section tree
  line_map = {},      -- line -> section lookup
  dirty_ranges = {},  -- Changed line ranges awaiting reparse

  -- Metadata
  article_name = "",
  tags = {},
  stats = { tasks = 0, completed = 0 }
}
```

#### Buffer Integration

```lua
-- Autocmd setup
vim.api.nvim_create_autocmd({"BufReadPost", "BufNewFile"}, {
  pattern = "*.zortex",
  callback = function(args)
    DocumentManager:load_buffer(args.buf, args.file)
  end
})

vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
  pattern = "*.zortex",
  callback = vim.schedule_wrap(function(args)
    DocumentManager:mark_buffer_dirty(args.buf,
      args.data.firstline,
      args.data.lastline)
  end)
})

-- Debounced reparse
local reparse_timer = nil
function DocumentManager:mark_buffer_dirty(bufnr, start_line, end_line)
  local doc = self.buffers[bufnr]
  if not doc then return end

  table.insert(doc.dirty_ranges, {start_line, end_line})

  -- Debounce reparse by 300ms
  if reparse_timer then
    vim.fn.timer_stop(reparse_timer)
  end

  reparse_timer = vim.fn.timer_start(300, function()
    self:reparse_dirty_ranges(bufnr)
    EventBus:emit("document:changed", {
      bufnr = bufnr,
      document = doc
    })
  end)
end
```

### 2. EventBus

The EventBus decouples modules while respecting Vim's event loop constraints.

#### Design Options

**Option 1: Priority-Based Async Queue** ⭐ RECOMMENDED

```lua
EventBus = {
  handlers = {}, -- event -> { {handler, priority, async} }
  queue = PriorityQueue:new()
}
```

- ✅ Guarantees handler order
- ✅ High-priority handlers run first
- ✅ Natural async support

**Option 2: Simple Pub/Sub**

```lua
EventBus = {
  handlers = {} -- event -> handler[]
}
```

- ✅ Dead simple
- ❌ No execution order guarantees
- ❌ All handlers block equally

**Option 3: Actor Model**

```lua
-- Each service is an actor with mailbox
EventBus = {
  actors = {} -- service -> mailbox
}
```

- ✅ True isolation
- ❌ Overengineered for Vim
- ❌ Hard to debug

#### Recommended Implementation

```lua
-- core/event_bus.lua
local EventBus = {
  handlers = {},     -- event -> handler_list
  middleware = {},   -- Global processors
  is_processing = false
}

-- Handler registration with smart defaults
function EventBus:on(event, handler, opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    priority = 50,
    async = true,    -- Default async!
    max_time = 100,  -- Warn if handler takes >100ms
  })

  local wrapped_handler = function(data)
    local start = vim.loop.hrtime()

    local function run()
      local ok, err = xpcall(handler, debug.traceback, data)

      local elapsed = (vim.loop.hrtime() - start) / 1e6
      if elapsed > opts.max_time then
        vim.notify(string.format(
          "Slow event handler: %s took %.1fms",
          event, elapsed
        ), vim.log.levels.WARN)
      end

      if not ok then
        vim.notify("Event handler error: " .. err, vim.log.levels.ERROR)
      end
    end

    if opts.async then
      vim.schedule(run)
    else
      run()
    end
  end

  -- Insert sorted by priority
  local handlers = self:ensure_handler_list(event)
  table.insert(handlers, {
    fn = wrapped_handler,
    priority = opts.priority,
    original = handler -- For removal
  })

  table.sort(handlers, function(a, b)
    return a.priority > b.priority
  end)
end

-- Emit with optional sync mode for critical paths
function EventBus:emit(event, data, opts)
  opts = opts or {}
  local handlers = self.handlers[event] or {}

  -- Apply middleware
  for _, mw in ipairs(self.middleware) do
    local continue, new_data = mw(event, data)
    if not continue then return end
    data = new_data or data
  end

  -- Execute handlers
  if opts.sync then
    -- Rare case: execute immediately in order
    for _, h in ipairs(handlers) do
      h.fn(data)
    end
  else
    -- Normal case: let handlers self-schedule
    for _, h in ipairs(handlers) do
      h.fn(data)
    end
  end
end
```

### 3. Service Layer

Services encapsulate business logic while remaining stateless and testable.

#### Design Options

**Option 1: Functional Services** ⭐ RECOMMENDED

```lua
-- Services are modules with pure functions
TaskService = {}
function TaskService.complete_task(task_id, context)
  -- Pure logic, emits events
end
```

- ✅ Simple to test
- ✅ No hidden state
- ✅ Easy composition

**Option 2: Object Services**

```lua
-- Services are instantiated objects
TaskService = class()
function TaskService:init(deps)
  self.repo = deps.repo
end
```

- ✅ Explicit dependencies
- ❌ More boilerplate
- ❌ Lifecycle management

**Option 3: Registry Pattern**

```lua
-- Services auto-register in container
ServiceContainer = {}
ServiceContainer:register("tasks", TaskService)
```

- ✅ Dependency injection
- ❌ Magic registration
- ❌ Hard to trace deps

#### Recommended Implementation

```lua
-- services/task_service.lua
local TaskService = {}

-- Complete a task (pure business logic)
function TaskService.complete_task(task_id, context)
  -- Get task from document
  local doc = DocumentManager:get_buffer(context.bufnr)
  local task = doc:get_task(task_id)

  if not task then
    error("Task not found: " .. task_id)
  end

  if task.completed then
    return nil, "Task already completed"
  end

  -- Calculate XP (pure calculation)
  local xp_context = {
    task_position = task.position,
    total_tasks = task.project.total_tasks,
    project_name = task.project.name,
    area_links = task.area_links
  }

  -- Emit event - let XPService handle calculation
  EventBus:emit("task:completing", {
    task = task,
    xp_context = xp_context,
    bufnr = context.bufnr
  })

  -- Update buffer through DocumentManager
  doc:update_task(task_id, { completed = true })

  -- Emit completion event
  EventBus:emit("task:completed", {
    task = task,
    bufnr = context.bufnr
  })

  return task
end

-- XPService listens and calculates
XPService.init = function()
  EventBus:on("task:completing", function(data)
    local xp = XPCalculator.calculate_task_xp(data.xp_context)

    -- Store XP award
    XPStore:add_task_xp(data.task.id, xp)

    EventBus:emit("xp:awarded", {
      source = "task",
      amount = xp,
      task_id = data.task.id
    })
  end)
end
```

### 4. Section-First Design

Sections become the primary abstraction for all operations.

```lua
-- core/section.lua
Section = {
  type = "article|heading|bold|label",
  level = 1,        -- For headings
  text = "",        -- Display text

  -- Tree structure
  parent = nil,
  children = {},

  -- Buffer location
  start_line = 1,
  end_line = 10,

  -- Computed properties
  path = {},        -- Parent chain
  id = "",          -- Unique identifier

  -- Content
  tasks = {},       -- Task models
  links = {},       -- Parsed links
  attributes = {},  -- Section attributes
}

-- Section methods
function Section:contains_line(line)
  return line >= self.start_line and line <= self.end_line
end

function Section:get_breadcrumb()
  local parts = {}
  for _, section in ipairs(self.path) do
    table.insert(parts, section.text)
  end
  table.insert(parts, self.text)
  return table.concat(parts, " > ")
end
```

### 5. XP System Refactoring

The XP system becomes a set of loosely coupled services.

```lua
-- xp/calculator.lua (Pure functions)
XPCalculator = {}

function XPCalculator.calculate_task_xp(context)
  local cfg = Config.xp.task_rewards

  if context.total_tasks == 1 then
    return cfg.single_task
  end

  if context.task_position == context.total_tasks then
    -- Completion bonus
    return cfg.base * cfg.completion_multiplier + cfg.completion_bonus
  end

  if context.task_position <= cfg.initiation_threshold then
    -- Early task bonus
    return cfg.base * cfg.initiation_multiplier
  end

  return cfg.base
end

-- xp/distributor.lua (Handles XP flow)
XPDistributor = {}

function XPDistributor.init()
  -- Listen for XP awards
  EventBus:on("xp:awarded", function(data)
    local distributions = {}

    -- Add to season
    if SeasonStore:has_active_season() then
      table.insert(distributions, {
        type = "season",
        amount = data.amount
      })
    end

    -- Transfer to areas (10% of task XP)
    if data.source == "task" and data.area_links then
      local area_amount = math.floor(data.amount * 0.1 / #data.area_links)
      for _, area in ipairs(data.area_links) do
        table.insert(distributions, {
          type = "area",
          target = area,
          amount = area_amount
        })
      end
    end

    -- Apply distributions
    for _, dist in ipairs(distributions) do
      if dist.type == "season" then
        SeasonStore:add_xp(dist.amount)
      elseif dist.type == "area" then
        AreaStore:add_xp(dist.target, dist.amount)
      end
    end

    EventBus:emit("xp:distributed", {
      original = data,
      distributions = distributions
    })
  end)
end
```

### 6. Persistence Strategy

#### Design Options

**Option 1: Write-Through with Debounce** ⭐ RECOMMENDED

```lua
-- Writes to memory immediately, persists on schedule
PersistenceManager = {
  dirty_stores = {},
  save_timer = nil,
  save_interval = 5000 -- 5 seconds
}
```

- ✅ Responsive UI
- ✅ Batched I/O
- ✅ Crash recovery via timer

**Option 2: Write-Behind on Events**

```lua
-- Only saves on specific events
PersistenceManager = {
  save_on = {"BufWritePost", "VimLeavePre"}
}
```

- ✅ Predictable saves
- ❌ Can lose data on crash
- ❌ No auto-save

**Option 3: Transaction Log**

```lua
-- Append-only log with periodic compaction
TransactionLog = {
  log_file = ".z/transactions.log"
}
```

- ✅ Never lose data
- ❌ Complex for Vim plugin
- ❌ Log growth issues

#### Recommended Implementation

```lua
-- stores/persistence_manager.lua
local PersistenceManager = {
  dirty_stores = {},
  save_timer = nil,
  save_interval = 5000,
  is_saving = false
}

function PersistenceManager:mark_dirty(store_name)
  self.dirty_stores[store_name] = true
  self:schedule_save()
end

function PersistenceManager:schedule_save()
  -- Cancel existing timer
  if self.save_timer then
    vim.fn.timer_stop(self.save_timer)
  end

  -- Schedule new save
  self.save_timer = vim.fn.timer_start(self.save_interval, function()
    vim.schedule(function()
      self:save_all()
    end)
  end)
end

function PersistenceManager:save_all()
  if self.is_saving then return end
  self.is_saving = true

  local saved = {}
  for store_name, _ in pairs(self.dirty_stores) do
    local store = require("zortex.stores." .. store_name)
    if store.save then
      local ok, err = pcall(store.save, store)
      if ok then
        table.insert(saved, store_name)
      else
        vim.notify("Failed to save " .. store_name .. ": " .. err,
                  vim.log.levels.ERROR)
      end
    end
  end

  self.dirty_stores = {}
  self.is_saving = false

  if #saved > 0 then
    EventBus:emit("stores:saved", { stores = saved })
  end
end

-- Auto-save on exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    PersistenceManager:save_all()
  end
})
```

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)

**Goal:** Build core infrastructure without breaking existing features

1. **Week 1: EventBus & DocumentManager Shell**

   - Implement EventBus with tests
   - Create DocumentManager interface
   - Add buffer autocmds
   - Set up performance logging

2. **Week 2: Section Parser & Tree**
   - Port parser to use Section models
   - Implement incremental parsing
   - Add section tree navigation
   - Create buffer-section index

**Deliverable:** Can parse and query sections; existing code still works

### Phase 2: Service Extraction (Weeks 3-4)

**Goal:** Extract business logic to services

3. **Week 3: Task & XP Services**

   - Create TaskService with event emissions
   - Extract XP calculations to domain layer
   - Implement XPDistributor
   - Add service tests

4. **Week 4: Wire Services to UI**
   - Update commands to use services
   - Add EventBus listeners
   - Implement persistence manager
   - Keep backward compatibility shims

**Deliverable:** New architecture handles tasks/XP; old code being strangled

### Phase 3: Feature Migration (Weeks 5-6)

**Goal:** Migrate remaining features to new architecture

5. **Week 5: Search & Projects**

   - Rebuild search on DocumentManager
   - Migrate project operations
   - Update calendar service
   - Port archive features

6. **Week 6: Polish & Performance**
   - Add comprehensive error handling
   - Implement retry logic
   - Profile and optimize hot paths
   - Add memory limits

**Deliverable:** All features use new architecture; performance validated

### Phase 4: Cleanup & Documentation (Weeks 7-8)

**Goal:** Remove old code and document new system

7. **Week 7: Code Removal**

   - Delete old modules
   - Remove compatibility shims
   - Update all tests
   - Fix edge cases

8. **Week 8: Documentation & Training**
   - Write architecture guide
   - Create developer docs
   - Record demo videos
   - Team training

**Deliverable:** Clean codebase with full documentation

## Risk Mitigation

### Technical Risks

| Risk                   | Impact | Mitigation                                        |
| ---------------------- | ------ | ------------------------------------------------- |
| Tree-sitter complexity | High   | Start with regex parser; TS as future enhancement |
| Memory growth          | Medium | Implement hard limits and LRU eviction            |
| Event loops            | Medium | Add recursion detection and event limits          |
| Data loss              | High   | Auto-save timer + transaction recovery            |
| Performance regression | Medium | Benchmark suite run on every PR                   |

### Process Risks

| Risk            | Impact | Mitigation                             |
| --------------- | ------ | -------------------------------------- |
| Scope creep     | High   | Strict phase gates; defer enhancements |
| Team alignment  | Medium | Weekly architecture reviews            |
| User disruption | High   | Feature flags for gradual rollout      |
| Knowledge gaps  | Medium | Pair programming + documentation       |

## Success Metrics

### Performance

- Task toggle: < 16ms (from 50ms)
- Search results: < 100ms for 10k sections
- Memory usage: < 50MB for typical workflow
- Startup time: < 100ms

### Code Quality

- Cyclomatic complexity: < 10 per function
- Test coverage: > 80%
- Module coupling: < 3 dependencies per module
- Documentation: 100% public API coverage

### Developer Experience

- Onboarding time: < 2 hours to make first change
- Debug time: 50% reduction in issue resolution
- Feature velocity: 2x increase in features/month

## Appendix: Migration Examples

### Example 1: Migrating Task Toggle

**Before:**

```lua
-- modules/tasks.lua
function M.toggle_current_task()
  local line = vim.api.nvim_get_current_line()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Complex parsing
  local is_task, is_done = parser.is_task_line(line)
  if not is_task then return end

  -- Direct buffer manipulation
  local new_line = toggle_checkbox(line)
  vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, {new_line})

  -- Scattered XP logic
  if not is_done then
    local xp = calculate_xp(...)
    xp_projects.complete_task(...)
    xp_areas.add_xp(...)
  end
end
```

**After:**

```lua
-- ui/keymaps.lua
function toggle_current_task()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local bufnr = vim.api.nvim_get_current_buf()

  -- Simple service call
  TaskService.toggle_task_at_line({
    bufnr = bufnr,
    lnum = lnum
  })
end

-- services/task_service.lua
function TaskService.toggle_task_at_line(context)
  local doc = DocumentManager:get_buffer(context.bufnr)
  local section = doc:get_section_at_line(context.lnum)
  local task = section:get_task_at_line(context.lnum)

  if not task then return end

  if task.completed then
    TaskService.uncomplete_task(task.id, context)
  else
    TaskService.complete_task(task.id, context)
  end
end
```

### Example 2: Adding a New Feature

**Task Dependencies Example:**

```lua
-- 1. Add to domain model
-- domain/task_states.lua
TaskStates = {
  BLOCKED = "blocked",
  READY = "ready",
  IN_PROGRESS = "in_progress",
  DONE = "done"
}

-- 2. Create service method
-- services/task_service.lua
function TaskService.update_dependencies(task_id, context)
  local doc = DocumentManager:get_buffer(context.bufnr)
  local task = doc:get_task(task_id)

  -- Check if dependencies are met
  local all_deps_done = true
  for _, dep_id in ipairs(task.depends_on) do
    local dep = doc:get_task(dep_id)
    if not dep.completed then
      all_deps_done = false
      break
    end
  end

  -- Update state
  local new_state = all_deps_done and TaskStates.READY or TaskStates.BLOCKED
  doc:update_task(task_id, { state = new_state })

  EventBus:emit("task:state_changed", {
    task_id = task_id,
    old_state = task.state,
    new_state = new_state
  })
end

-- 3. Listen for completion events
EventBus:on("task:completed", function(data)
  -- Check all tasks that depend on this one
  local doc = DocumentManager:get_buffer(data.bufnr)
  for _, task in ipairs(doc:get_all_tasks()) do
    if vim.tbl_contains(task.depends_on or {}, data.task.id) then
      TaskService.update_dependencies(task.id, { bufnr = data.bufnr })
    end
  end
end)
```

## Conclusion

This architecture transformation will reduce cognitive load by 70% through clear separation of concerns, event-driven communication, and buffer-centric design. The phased approach ensures continuous delivery of value while systematically eliminating technical debt.

The key insight is treating sections as first-class citizens and the buffer as the source of truth, which aligns perfectly with Vim's philosophy while enabling powerful features like incremental parsing and real-time updates.

Start with Phase 1 immediately - the EventBus and DocumentManager provide immediate value and unblock all subsequent work.
