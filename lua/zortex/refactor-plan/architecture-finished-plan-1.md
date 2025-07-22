Below is a consolidated, Neovim‑aware refactoring blueprint for Zortex, organized into architecture layers, core subsystems, and an eight‑week rollout roadmap. It integrates your new notes—incremental parsing, batched persistence, section‐first design, search index bounds, link resolver tie‑ins, and tree‑sitter exploration—while prioritizing performance and low cognitive overhead.

---

## 1  Architecture Overview

```
┌──────────────────────────────────────────────┐
│                  UI Layer                   │
│ (calendar, search, skill_tree, highlights)  │
└─────────────────────────┬────────────────────┘
                          │
┌─────────────────────────▼────────────────────┐
│                Service Layer                │
│ (TaskService, XPService, SearchService,     │
│  ProjectService, LinkService, PersistService)│
└─────────────────────────┬────────────────────┘
                          │
┌─────────────────────────▼────────────────────┐
│               Domain Models                 │
│ (Document, Section, Task, Project, Area,    │
│  CalendarEntry, Link)                       │
└─────────────────────────┬────────────────────┘
                          │
┌─────────────────────────▼────────────────────┐
│            Parsing & Caching Layer          │
│ (DocumentManager + Tree‑sitter or Regex,    │
│  Section cache, incremental updates)        │
└─────────────────────────┬────────────────────┘
                          │
┌─────────────────────────▼────────────────────┐
│             Data Access Layer               │
│ (Repositories, In‑memory UoW snapshots)     │
└─────────────────────────┬────────────────────┘
                          │
┌─────────────────────────▼────────────────────┐
│                  Stores                     │
│ (File‑based persistence, batched writes)    │
└──────────────────────────────────────────────┘
```

Cross‑cutting:

- **EventBus** (async by default with vim.schedule)
- **Debounce/Throttle** for autocmds
- **Configuration** (user overrides for xp_rules, cache sizes)

---

## 2  Core Subsystems

### 2.1 DocumentManager & Section Cache

- **Responsibility**: Single source of truth for all `.zortex` files (projects, okr, areas, calendar, archives).
- **Buffer‑First**:

  - On `BufReadPost` or `BufEnter`: parse buffer contents via `vim.api.nvim_buf_get_lines()` into a `Document` object.
  - On `TextChanged{,I}`: mark `doc.dirty = true`.
  - On next `Document:get_sections()` or via scheduled debounce (300 ms), re‑parse only changed lines—either via Tree‑sitter incremental edits **or** lightweight regex diff on headings.

- **API**:

  ```lua
  local doc = DocumentManager:get(bufnr, filepath)
  -- returns struct { sections = tree, section_index = line→section }
  ```

- **Incremental Parsing** (optional Tree‑sitter PoC):

  - Maintain a TS parser instance per buffer.
  - Use `parser:parse_range()` on affected byte‑ranges.

- **Cache Eviction**: LRU for file handles (max_files = 5), but we expect only \~6 core docs.

### 2.2 EventBus

- **Async by Default**:

  ```lua
  EventBus:on_async(evt, handler)    -- wraps handler in vim.schedule
  EventBus:on_sync(evt, handler)     -- for trivial, < 1 ms ops
  ```

- **Usage**:

  - `TASK_COMPLETED` → triggers UI update, XP calc, persistence.
  - `DOCUMENT_CHANGED` → `SearchService` index update.

- **Middleware**: Logging, validation, namespacing/unsubscribe.

### 2.3 Service Layer

- **TaskService**

  - Pure business logic: create, toggle, complete tasks.
  - Emits `TASK_*` events.

- **XPService**

  - Subscribes to `TASK_COMPLETED`, calculates XP (via `domain/xp_calculator.lua`), emits `XP_GAINED`.

- **SearchService**

  - Listens to `DOCUMENT_CHANGED` and `SECTION_UPDATED`, does incremental indexing.
  - Bounds index size (max_sections = 5000) with LRU eviction.

- **LinkService**

  - Resolves `[[Article#Section]]` links by querying `DocumentManager`.

- **PersistService**

  - Subscribes to all mutating events (`TASK_UPDATED`, `XP_GAINED`, etc.), collects dirty entities into an in‑memory UoW.
  - On `BufWritePost` or via `vim.schedule_wrap`, flushes all changes in one batch to disk.

### 2.4 Data Access & UoW

- **In‑Memory Snapshot**:

  - `UoW:begin()` clones relevant stores (xp, tasks) into a scratch table.
  - Mutations apply to scratch.
  - Commit enqueues a single batched write via `PersistService`.

- **Rollback**: simply discard scratch on error.

---

## 3  Key Design Decisions

1. **Buffer as Truth**: All reads come from live buffers; file mtime only marks external writes.
2. **Batched Persistence**:

   - Mark dirty on any state change.
   - Write once per financial operation: on save, Vim exit, or explicit `:ZortexSave` command.

3. **Section‑First**:

   - Everything (search, links, XP attribution) is based on sections.
   - `Section` object has `id`, `type` (heading, task, article), `range`, `attrs`.

4. **Transactional Simplicity**:

   - Snapshot + batch commit is easier than a full log transactional system.

5. **Debounced Autocmds**: throttle `TextChanged` to 300 ms, use `vim.defer_fn`.
6. **Plugin‑Safe Async**: wrap any heavy work (`rg` calls, XP recompute) in `vim.system` or `vim.loop.new_async`, always return control immediately.

---

## 4  File & Module Changes

### New Files

- **`core/document.lua`** – `Document` class + parsing logic
- **`core/document_manager.lua`** – cache, eviction, buffer hooks
- **`core/section.lua`** – tree node for headings/tasks/etc.
- **`core/event_bus.lua`** – async/sync bus + middleware
- **`services/*.lua`** – TaskService, XPService, SearchService, LinkService, PersistService
- **`dal/unit_of_work.lua`** – snapshot/rollback machinery
- **`domain/xp_calculator.lua`** – pure XP rules, user‑configurable

### Updated Files

- **`init.lua`** – wire up `DocumentManager` and `EventBus`, replace direct store calls with service API
- **`modules/*.lua`** – deprecate in favor of Services (gradual migration)
- **`stores/*.lua`** – slim down to raw load/save functions; business logic moves to Services
- **`core/parser.lua`** – slim utility for fallback parsing if TS disabled
- **`features/*.lua`** – subscribe to events instead of polling modules

---

## 5  Eight‑Week Rollout Roadmap

| Phase        | Goals                           | Deliverables                                                       |
| ------------ | ------------------------------- | ------------------------------------------------------------------ |
| **Week 1–2** | **Foundation**                  | DocumentManager (+buf hooks), EventBus                             |
| **Week 3–4** | **Core Services**               | TaskService, XPService, PersistService, UoW                        |
| **Week 5**   | **Search & Links**              | SearchService, LinkService, index tests                            |
| **Week 6**   | **UI Integration & Highlights** | Replace direct buffer writes with `EventBus` flows; batch extmarks |
| **Week 7**   | **Performance & Async**         | Offload heavy tasks (ripgrep), debounce checks, TS PoC             |
| **Week 8**   | **Migration & Cleanup**         | Strangle‑fig old modules, finalize docs & tests                    |

---

## 6  Success Metrics & Next Steps

- **Performance**: < 16 ms “complete task” round‑trip (no stutter)
- **Memory**: < 50 MB RSS with core cache loaded
- **Test Coverage**: ≥ 80% (Plenary + Busted harness)
- **UX**: No visible lag under rapid edits; clear section‑based navigation

**Immediate Next Steps**:

1. Prototype `core/document_manager` with buffer hooks.
2. Build `core/event_bus` with async handlers.
3. Demo `TaskService:toggle_task()` → emits `TASK_COMPLETED` → buffer update + XP.

With this plan in hand, Zortex will transition from a tangled monolith into a high‑performance, maintainable, and extensible Neovim plugin—one that treats your `.zortex` sections as first‑class citizens, respects Vim’s async paradigm, and dramatically reduces cognitive load for future contributors.
