# Zortex Architecture Refactoring Plan

## Executive Summary

This plan outlines a comprehensive refactoring of the Zortex codebase to improve maintainability, reduce cognitive load, and enable easier feature development. The primary goals are to implement a service layer architecture, event-driven communication, and a centralized file parsing/caching system.

---

## 1. Core Architecture Vision

### Current Problems

- **Tight Coupling**: Modules directly call each other creating circular dependencies
- **Scattered Logic**: Business logic mixed with data access and UI concerns
- **Duplicate Parsing**: Multiple modules parse the same files independently
- **No Transaction Support**: Changes can partially fail leaving inconsistent state
- **Hard to Test**: Direct dependencies make unit testing difficult

### Proposed Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│  (calendar.lua, search.lua, skill_tree.lua, telescope.lua)  │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    Service Layer                             │
│  (TaskService, XPService, SearchService, ProjectService)    │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Domain Models                               │
│    (Task, Project, Area, CalendarEntry, SearchResult)       │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│               Data Access Layer                              │
│         (Repositories + Unit of Work)                        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                     Stores                                   │
│    (File-based persistence with caching)                     │
└─────────────────────────────────────────────────────────────┘

Cross-cutting concerns:
- Event Bus (all layers)
- File Parser/Cache (services + repositories)
- Configuration (all layers)
```

---

## 2. File Parsing and Caching System

### Synopsis

A centralized system that parses Zortex files once and provides cached, structured access to all modules. This eliminates duplicate parsing and provides consistent section understanding across the codebase.

### Problems Solved

- Multiple modules parsing the same files repeatedly
- Inconsistent section boundary detection
- Performance issues from repeated file I/O
- Memory waste from duplicate parsing

### Design

#### Option 1: Lazy Document Model (Recommended)

```lua
-- core/document.lua
local Document = {
    file_path = "path/to/file.zortex",
    raw_lines = {}, -- Original file lines
    sections = {},  -- Parsed section tree
    index = {},     -- Line number to section mapping
    dirty = false,  -- Needs reparse
    version = 0     -- For change tracking
}
```

**Pros:**

- Lazy loading of sections
- Memory efficient
- Easy invalidation
- Natural tree structure

**Cons:**

- Initial parse overhead
- Complex update logic

#### Option 2: Stream-based Parser

```lua
-- core/parser_stream.lua
local ParserStream = {
    file_handle = io.open(...),
    buffer_size = 4096,
    current_section = nil
}
```

**Pros:**

- Very memory efficient
- Good for large files
- Can parse partial files

**Cons:**

- No random access
- Can't cache effectively
- Complex implementation

### Recommended Implementation

```lua
-- core/document_manager.lua
local DocumentManager = {}
local documents = {} -- path -> Document cache

function DocumentManager:get_document(filepath)
    local doc = documents[filepath]

    -- Check if needs refresh
    if not doc or self:is_stale(doc) then
        doc = self:parse_document(filepath)
        documents[filepath] = doc
    end

    return doc
end

function DocumentManager:parse_document(filepath)
    local lines = fs.read_lines(filepath)
    local doc = Document:new(filepath, lines)

    -- Parse sections lazily
    doc:parse_sections()

    return doc
end

-- core/document.lua
local Document = {}
Document.__index = Document

function Document:new(filepath, lines)
    return setmetatable({
        filepath = filepath,
        lines = lines,
        sections = {},
        section_index = {}, -- line -> section mapping
        parsed = false,
        mtime = vim.fn.getftime(filepath)
    }, self)
end

function Document:parse_sections()
    if self.parsed then return end

    local section_stack = {}
    local root = Section:new("root", "file", 0, 0)

    for i, line in ipairs(self.lines) do
        local section_type = parser.detect_section_type(line)

        if section_type ~= SECTION_TYPE.TEXT then
            local section = self:create_section(i, line, section_type)

            -- Find parent based on hierarchy
            while #section_stack > 0 do
                local parent = section_stack[#section_stack]
                if parent:can_contain(section) then
                    parent:add_child(section)
                    break
                else
                    table.remove(section_stack)
                end
            end

            table.insert(section_stack, section)
        end

        -- Map line to current section
        self.section_index[i] = section_stack[#section_stack] or root
    end

    self.sections = root
    self.parsed = true
end

function Document:get_section_at_line(line_num)
    if not self.parsed then
        self:parse_sections()
    end
    return self.section_index[line_num]
end

function Document:get_section_range(start_line, end_line)
    -- Returns all sections in range
    local sections = {}
    local current_section = nil

    for i = start_line, end_line do
        local section = self.section_index[i]
        if section ~= current_section then
            table.insert(sections, section)
            current_section = section
        end
    end

    return sections
end
```

### Files Needed

- `core/document_manager.lua` - Document cache management
- `core/document.lua` - Document model
- `core/section.lua` - Section model with hierarchy
- `stores/document_cache.lua` - Persistent cache for parsed documents
- `tests/core/document_spec.lua` - Tests

---

## 3. Event System Architecture

### Synopsis

Implement a centralized event bus to decouple modules and enable reactive programming patterns. This allows modules to communicate without direct dependencies.

### Problems Solved

- Circular dependencies between modules
- Hard to add new features that react to existing events
- No central place to see system behavior
- Difficult to test modules in isolation

### Design Options

#### Option 1: Synchronous Event Bus (Recommended for Simplicity)

```lua
-- core/events.lua
local EventBus = {}
EventBus.handlers = {}

function EventBus:on(event, handler, priority)
    -- Handlers executed immediately in order
end

function EventBus:emit(event, data)
    -- Synchronous execution
end
```

**Pros:**

- Simple to understand
- Predictable execution order
- Easy debugging
- No async complexity

**Cons:**

- Can block UI
- No parallel execution

#### Option 2: Actor Model

```lua
-- core/actor.lua
local Actor = {}
Actor.mailbox = {}

function Actor:send(message)
    -- Queue message
end

function Actor:receive()
    -- Process messages
end
```

**Pros:**

- True isolation
- Concurrent execution
- Fault tolerance

**Cons:**

- Complex for Neovim
- Hard to debug
- Overkill for this use case

### Recommended Implementation

```lua
-- core/event_bus.lua
local EventBus = {}
EventBus.__index = EventBus

-- Singleton instance
local instance = nil

function EventBus:new()
    if instance then return instance end

    instance = setmetatable({
        handlers = {},      -- event -> handler list
        middleware = {},    -- global middleware
        history = {},       -- event history for debugging
        config = {
            history_size = 100,
            enable_logging = false
        }
    }, self)

    return instance
end

function EventBus:on(event, handler, options)
    options = options or {}

    if not self.handlers[event] then
        self.handlers[event] = {}
    end

    local entry = {
        handler = handler,
        priority = options.priority or 50,
        once = options.once or false,
        namespace = options.namespace -- for bulk removal
    }

    table.insert(self.handlers[event], entry)
    self:sort_handlers(event)

    -- Return unsubscribe function
    return function()
        self:off(event, handler)
    end
end

function EventBus:emit(event, data)
    -- Record event
    self:record_event(event, data)

    -- Run middleware
    for _, middleware in ipairs(self.middleware) do
        local continue, new_data = middleware(event, data)
        if not continue then return end
        data = new_data or data
    end

    -- Execute handlers
    local handlers = self.handlers[event] or {}
    local to_remove = {}

    for i, entry in ipairs(handlers) do
        local ok, err = pcall(entry.handler, data)

        if not ok then
            self:handle_error(event, entry, err)
        end

        if entry.once then
            table.insert(to_remove, i)
        end
    end

    -- Remove once handlers
    for i = #to_remove, 1, -1 do
        table.remove(handlers, to_remove[i])
    end
end

-- Event definitions
local Events = {
    -- Task events
    TASK_CREATED = "task:created",
    TASK_COMPLETED = "task:completed",
    TASK_UNCOMPLETED = "task:uncompleted",
    TASK_UPDATED = "task:updated",
    TASK_DELETED = "task:deleted",

    -- Project events
    PROJECT_CREATED = "project:created",
    PROJECT_COMPLETED = "project:completed",
    PROJECT_PROGRESS_UPDATED = "project:progress_updated",

    -- XP events
    XP_GAINED = "xp:gained",
    LEVEL_UP = "xp:level_up",
    SEASON_STARTED = "season:started",
    SEASON_ENDED = "season:ended",

    -- Document events
    DOCUMENT_CHANGED = "document:changed",
    SECTION_UPDATED = "section:updated"
}

return EventBus, Events
```

### Files Needed

- `core/event_bus.lua` - Main event system
- `core/events.lua` - Event constant definitions
- `core/middleware/logging.lua` - Event logging middleware
- `core/middleware/validation.lua` - Event data validation
- `tests/core/event_bus_spec.lua` - Tests

---

## 4. Service Layer Architecture

### Synopsis

Implement a service layer that encapsulates all business logic, coordinates between repositories, and emits events. Services are the only place where business rules live.

### Problems Solved

- Business logic scattered across UI and data layers
- No transaction boundaries
- Difficult to test business rules
- Hard to understand system behavior

### Design Principles

1. **Single Responsibility**: Each service handles one domain
2. **No Direct Dependencies**: Services communicate via events
3. **Transaction Boundaries**: Services define transaction scope
4. **Pure Business Logic**: No UI or data access concerns

### Implementation

```lua
-- services/base_service.lua
local BaseService = {}
BaseService.__index = BaseService

function BaseService:new(config)
    return setmetatable({
        events = config.events or require("core.event_bus"):new(),
        uow = config.uow or require("dal.unit_of_work"):new(),
        logger = config.logger or require("core.logger"),
        config = config
    }, self)
end

function BaseService:with_transaction(fn)
    self.uow:begin()

    local ok, result = pcall(fn)

    if ok then
        self.uow:commit()
        return result
    else
        self.uow:rollback()
        error(result)
    end
end

-- services/task_service.lua
local TaskService = {}
TaskService.__index = TaskService
setmetatable(TaskService, { __index = BaseService })

function TaskService:new(config)
    local self = BaseService.new(self, config)
    self.task_repo = config.task_repo or require("dal.repositories.task_repository"):new(self.uow)
    self.xp_service = config.xp_service -- Injected to avoid circular dep
    return self
end

function TaskService:complete_task(task_id, context)
    return self:with_transaction(function()
        -- Load task
        local task = self.task_repo:find(task_id)
        if not task then
            error("Task not found: " .. task_id)
        end

        if task.completed then
            error("Task already completed")
        end

        -- Update task
        task.completed = true
        task.completed_at = os.time()

        -- Calculate XP (delegated to XP service)
        local xp_gained = 0
        if self.xp_service and context.project then
            xp_gained = self.xp_service:calculate_task_xp({
                task = task,
                project = context.project,
                position = context.position,
                total_tasks = context.total_tasks
            })
            task.xp_awarded = xp_gained
        end

        -- Save
        self.task_repo:save(task)

        -- Emit event
        self.events:emit(Events.TASK_COMPLETED, {
            task = task,
            xp_gained = xp_gained,
            context = context
        })

        return task, xp_gained
    end)
end

function TaskService:create_task(data)
    return self:with_transaction(function()
        -- Validate
        self:validate_task_data(data)

        -- Create task
        local task = Task:new({
            id = self:generate_id(),
            text = data.text,
            project = data.project,
            attributes = data.attributes,
            created_at = os.time()
        })

        -- Save
        self.task_repo:save(task)

        -- Emit event
        self.events:emit(Events.TASK_CREATED, {
            task = task
        })

        return task
    end)
end
```

### Files Needed

- `services/base_service.lua` - Base service class
- `services/task_service.lua` - Task business logic
- `services/xp_service.lua` - XP calculations
- `services/project_service.lua` - Project management
- `services/search_service.lua` - Search operations
- `services/container.lua` - Service dependency injection

---

## 5. XP System Refactoring

### Synopsis

Consolidate all XP logic into a single service with clear calculation rules and event-driven updates.

### Current Problems

- XP calculations scattered across multiple modules
- Circular dependencies between xp/areas.lua and xp/projects.lua
- No clear API for XP operations
- Hard to test XP rules

### Design

```lua
-- services/xp_service.lua
local XPService = {}
XPService.__index = XPService

function XPService:new(config)
    return setmetatable({
        events = config.events,
        area_repo = config.area_repo,
        project_repo = config.project_repo,
        calculator = require("domain.xp_calculator"):new(config.xp_config)
    }, self)
end

function XPService:calculate_task_xp(context)
    -- All XP calculation logic in one place
    local base_xp = self.calculator:task_xp(
        context.position,
        context.total_tasks
    )

    -- Apply modifiers
    local modifiers = self:get_modifiers(context)
    local final_xp = base_xp

    for _, modifier in ipairs(modifiers) do
        final_xp = modifier(final_xp, context)
    end

    return final_xp
end

function XPService:award_task_xp(task_id, xp_amount, context)
    -- Update project XP
    if context.project then
        self:add_project_xp(context.project, xp_amount)
    end

    -- Update season XP
    self:add_season_xp(xp_amount)

    -- Transfer to areas
    if context.area_links then
        self:transfer_to_areas(xp_amount, context.area_links)
    end

    -- Emit events
    self.events:emit(Events.XP_GAINED, {
        source = "task",
        task_id = task_id,
        amount = xp_amount,
        distributions = self:get_distributions(xp_amount, context)
    })
end

-- domain/xp_calculator.lua
local XPCalculator = {}

function XPCalculator:new(config)
    return setmetatable({
        curves = config.curves,
        multipliers = config.multipliers,
        rewards = config.rewards
    }, { __index = self })
end

function XPCalculator:task_xp(position, total)
    -- Pure calculation logic
    if total == 1 then
        return self.rewards.single_task
    end

    if position == total then
        -- Completion bonus
        return self.rewards.execution.base * self.rewards.completion.multiplier
            + self.rewards.completion.bonus
    end

    if position <= self.rewards.initiation.task_count then
        -- Early task bonus
        return self:calculate_initiation_xp(position)
    end

    return self.rewards.execution.base
end
```

### Migration Strategy

1. Create new XPService with all logic
2. Update TaskService to use XPService
3. Migrate UI to use XPService
4. Delete old xp/\* modules

### Files Needed

- `services/xp_service.lua` - Main XP service
- `domain/xp_calculator.lua` - Pure XP calculations
- `domain/xp_rules.lua` - XP business rules
- `repositories/xp_repository.lua` - XP data access

---

## 6. Search System Refactoring

### Synopsis

Rebuild search as a service using the document parser and an efficient index.

### Current Problems

- Complex search logic mixed with UI
- Rebuilds index on every search
- No background indexing
- Hard to extend search capabilities

### Design

```lua
-- services/search_service.lua
local SearchService = {}

function SearchService:new(config)
    return setmetatable({
        index = require("search.index"):new(),
        doc_manager = config.doc_manager,
        events = config.events,
        indexing = false
    }, { __index = self })
end

function SearchService:search(query, options)
    -- Ensure index is ready
    if not self.index:is_ready() then
        self:rebuild_index_sync()
    end

    -- Parse query
    local parsed_query = self:parse_query(query)

    -- Search index
    local results = self.index:search(parsed_query, options)

    -- Post-process results
    results = self:post_process(results, options)

    -- Track search for relevance
    self:track_search(query, results)

    return results
end

function SearchService:index_document(filepath)
    local doc = self.doc_manager:get_document(filepath)

    -- Extract searchable content
    local searchable = self:extract_searchable(doc)

    -- Update index
    self.index:add_document(filepath, searchable)

    self.events:emit(Events.DOCUMENT_INDEXED, {
        filepath = filepath,
        sections = #searchable.sections
    })
end

-- search/index.lua
local SearchIndex = {}

function SearchIndex:new()
    return setmetatable({
        documents = {},    -- filepath -> document
        tokens = {},       -- token -> document set
        sections = {},     -- section_id -> section
        trie = Trie:new(), -- For prefix search
    }, { __index = self })
end

function SearchIndex:search(query, options)
    local candidates = self:find_candidates(query)
    local scored = self:score_candidates(candidates, query)

    return self:apply_options(scored, options)
end
```

### Search Algorithm Options

#### Option 1: Inverted Index (Recommended)

- Fast lookups
- Good for exact matches
- Memory efficient

#### Option 2: Vector Embeddings

- Semantic search
- Requires external model
- Complex implementation

### Files Needed

- `services/search_service.lua` - Search orchestration
- `search/index.lua` - Core index
- `search/tokenizer.lua` - Text tokenization
- `search/scorer.lua` - Result scoring
- `search/query_parser.lua` - Query parsing

---

## 7. Code Quality Goals

### Metrics to Track

1. **Cyclomatic Complexity**: Max 10 per function
2. **Module Coupling**: No circular dependencies
3. **Test Coverage**: Minimum 80%
4. **Documentation**: All public APIs documented

### Coding Standards

```lua
-- Style Guide Example
local TaskService = {}
TaskService.__index = TaskService

--- Create a new TaskService instance
--- @param config table Configuration options
--- @return TaskService
function TaskService:new(config)
    assert(config.events, "TaskService requires events")
    assert(config.uow, "TaskService requires unit of work")

    return setmetatable({
        events = config.events,
        uow = config.uow
    }, self)
end

--- Complete a task
--- @param task_id string Task identifier
--- @param context table Completion context
--- @return Task|nil, string|nil Task and error
function TaskService:complete_task(task_id, context)
    -- Implementation
end
```

### Testing Strategy

```lua
-- Test Structure
describe("TaskService", function()
    local service
    local mock_events
    local mock_uow

    before_each(function()
        mock_events = create_mock_event_bus()
        mock_uow = create_mock_uow()

        service = TaskService:new({
            events = mock_events,
            uow = mock_uow
        })
    end)

    describe("complete_task", function()
        it("should complete an incomplete task", function()
            -- Arrange
            local task = create_test_task({ completed = false })
            mock_uow.task_repo.find = function() return task end

            -- Act
            local result = service:complete_task("123", {})

            -- Assert
            assert.is_true(result.completed)
            assert.spy(mock_events.emit).was_called_with(Events.TASK_COMPLETED)
        end)
    end)
end)
```

---

## 8. Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

1. **Document Parser System**

   - Implement Document and DocumentManager
   - Create Section model with hierarchy
   - Add caching layer
   - Write comprehensive tests

2. **Event System**
   - Implement EventBus
   - Define all system events
   - Add middleware support
   - Create debugging tools

### Phase 2: Service Layer (Week 3-4)

1. **Base Infrastructure**

   - BaseService class
   - Unit of Work pattern
   - Repository interfaces
   - Dependency injection

2. **XP Service**
   - Consolidate all XP logic
   - Create XPCalculator
   - Migrate existing code
   - Comprehensive tests

### Phase 3: Feature Services (Week 5-6)

1. **Task Service**

   - Extract from modules/tasks.lua
   - Use event system
   - Add transaction support

2. **Search Service**
   - Build on document parser
   - Implement incremental indexing
   - Add search analytics

### Phase 4: UI Migration (Week 7-8)

1. **Update UI Components**

   - Use services instead of modules
   - Subscribe to events
   - Remove direct store access

2. **Testing and Documentation**
   - Integration tests
   - Performance benchmarks
   - API documentation

---

## 9. Migration Guide

### For Each Module

1. **Identify Business Logic**

   - Extract to service
   - Define clear API

2. **Identify Data Access**

   - Move to repository
   - Use Unit of Work

3. **Identify Events**

   - Replace direct calls
   - Define event contracts

4. **Update Tests**
   - Mock services
   - Test in isolation

### Backward Compatibility

```lua
-- Compatibility layer during migration
local old_api = {}

function old_api.complete_task(...)
    -- Delegate to new service
    local service = require("services.container").task_service
    return service:complete_task(...)
end

return old_api
```

---

## 10. Risk Mitigation

### Technical Risks

1. **Performance Regression**

   - Mitigation: Benchmark before/after
   - Add caching strategically

2. **Breaking Changes**

   - Mitigation: Compatibility layer
   - Incremental migration

3. **Increased Complexity**
   - Mitigation: Clear documentation
   - Training materials

### Process Risks

1. **Long Migration Time**

   - Mitigation: Feature flags
   - Parallel development

2. **Team Coordination**
   - Mitigation: Clear ownership
   - Regular sync meetings

---

## Summary

This refactoring plan addresses the core maintainability issues in Zortex by:

1. **Centralizing file parsing** to eliminate duplication
2. **Implementing events** to decouple modules
3. **Creating services** to consolidate business logic
4. **Standardizing patterns** to reduce cognitive load

The phased approach allows incremental progress while maintaining stability. Each phase delivers value independently and sets up the next phase for success.
