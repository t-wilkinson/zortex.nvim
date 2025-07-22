# Zortex · Final Architecture & Refactoring Plan

> **Version 1.0 – July 21 2025**\
> *This document merges all prior critiques, your new requirements, and Neovim‑specific constraints into a single, authoritative blueprint.*

---

## 1 · Executive Summary

Zortex will transition to a **layered, event‑driven, async‑first architecture** that keeps the **buffer as the single source‑of‑truth** while enabling performant features like incremental parsing, reactive XP awards, and background search indexing.  The refactor is phased to deliver user‑visible value every 2 weeks while steadily strangling the legacy code.

### Core Goals

| ID | Goal                                        | Success Metric                                        |
| -- | ------------------------------------------- | ----------------------------------------------------- |
| G1 | Decouple modules via service & event layers | No circular `require` graphs (CI check)               |
| G2 | Non‑blocking UX                             | < 16 ms wall‑time on any key‑bound action (benchmark) |
| G3 | Lean memory footprint                       | ≤ 50 MB RSS after loading 1 000 *.zortex* buffers     |
| G4 | Proven correctness                          | ≥ 80 % unit‑test & 60 % integration‑test coverage     |

---

## 2 · Guiding Principles

1. **Buffer‑First Truth** – All live operations read from `nvim_buf_get_lines`; disk I/O is async.
2. **Async Everywhere** – Any I/O or compute > 4 ms is scheduled via `vim.schedule` or `vim.system` jobs.
3. **Event‑Driven Core** – Services communicate exclusively through the EventBus; no direct cross‑service calls.
4. **Incremental Parsing & Caching** – Tree‑sitter + LRU cache with autocommand invalidation.
5. **Small, Testable Units** – Pure‑Lua domain logic separated from Neovim API for headless testing.

---

## 3 · Layered Architecture

```text
UI  ────────────────────────────────────────────────── Zortex commands, keymaps, extmarks
│
├─ Service Layer ─ TaskService │ XPService │ SearchService │ DocumentService │ NotificationService
│
├─ Domain Models ─ Task │ Project │ Area │ Section │ CalendarEntry │ XPEvent
│
├─ Data Access ─ Repositories + Unit‑of‑Work (async commits)
│
└─ Stores ─ JSON/plain‑text persistence in .z/ directory  (lazy‑loaded)

Cross‑cutting: EventBus  ·  DocumentManager  ·  Config  ·  Logger
```

---

## 4 · Key Components

### 4.1 DocumentManager

- **Role**: Parse & cache `{archive|projects|okr|areas|calendar}.zortex` plus open buffers.
- **Tech**: Tree‑sitter with incremental `parse_range` patches.
- **Invalidation**: `BufReadPost`, `BufEnter` → parse; `TextChanged{,I}` → mark dirty & debounce 300 ms; `BufWritePost` syncs cache `mtime`.
- **API**:
  ```lua
  local doc = DocumentManager:get(bufnr)
  doc:get_section_at(line)
  doc:update_line(line, new_text) -- keeps index coherent
  ```
- **Memory Guard**: `LRU(max=5)`; evict least‑recent docs when threshold exceeded.

### 4.2 EventBus

- **Sync vs. Async**: `on_sync` for micro‑handlers (<1 ms); `on_async` wraps handler in `vim.schedule`.
- **Wildcard Topics**: e.g. `"task:*"`.
- **Middleware**: logging, payload validation, error isolation with `xpcall`.

### 4.3 Service Highlights

| Service                 | Responsibilities                                  | Key Events Emitted               |
| ----------------------- | ------------------------------------------------- | -------------------------------- |
| **TaskService**         | Toggle/convert tasks, mutate buffer, delegate XP  | `task:created`, `task:completed` |
| **XPService**           | Rule‑based XP calc, area + season progression     | `xp:gained`, `level:up`          |
| **SearchService**       | Token/LSP‑style fuzzy index, background rebuild   | `search:indexed`                 |
| **NotificationService** | Digest assembly, timer triggers, provider fan‑out | `notify:sent`, `digest:failed`   |
| **DocumentService**     | High‑level doc ops (archive move, bulk edits)     | `doc:changed`, `section:updated` |

### 4.4 XP Calculator

- Pure function module `domain/xp_calculator.lua` – deterministic, testable.
- Configurable via `require('zortex').setup{ xp = { curves = … } }`.

### 4.5 Search Index

- **Inverted Index** stored in `lua-resty-lrucache`‑style table.
- Rebuilt lazily; large‑file scan offloaded to `vim.system({ 'rg', … })` when available.

---

## 5 · Neovim‑Specific Patterns

1. **Namespaced Augroups** – `ZortexBuf`, `ZortexFS` to avoid collisions.
2. **Extmark Batching** – collect & apply in chunks of 100 rows.
3. **Lazy Loading** – parser on `BufReadPre *.zortex`; UI commands via `CmdUndefined Zortex*`.
4. **Healthchecks** – `:checkhealth zortex` validates Tree‑sitter, job control, providers.

---

## 6 · File & Module Layout

```
lua/zortex/
  core/      event_bus.lua  document_manager.lua  section.lua  logger.lua
  services/  task.lua  xp.lua  search.lua  notify.lua  document.lua
  domain/    xp_calculator.lua  rules.lua
  dal/       repositories.lua  unit_of_work.lua
  ui/        calendar.lua  telescope.lua  skill_tree.lua  …
  tests/     …
```

Legacy modules retained under `legacy/` and shim‑forwarded during migration.

---

## 7 · Migration Roadmap

| Phase                 | Weeks | Deliverables                                                  |
| --------------------- | ----- | ------------------------------------------------------------- |
| **P1 Foundation**     | 1‑2   | DocumentManager + Section model + EventBus (async) + tests    |
| **P2 Core Services**  | 3‑4   | TaskService + XPService with buffer integration; legacy shims |
| **P3 Search & Index** | 5‑6   | Incremental SearchService + Telescope rewrite                 |
| **P4 UI‑Strangle**    | 7‑8   | Port calendar & task UI to services; delete old stores        |
| **P5 Perf‑Polish**    | 9     | Benchmarks, profiler passes, memory audit                     |

*All phases gated by CI green & < 16 ms benchmark on task toggle.*

---

## 8 · Risk & Mitigation

| Risk                       | Mitigation                                  |
| -------------------------- | ------------------------------------------- |
| Event handler stalls UI    | Default async handlers, CI latency test     |
| Memory blow‑up on archives | LRU eviction + stream parser fallback       |
| Tree‑sitter edge‑cases     | Fallback to regex parser; integration tests |
| Large diff in user configs | Compatibility shims + deprecation warnings  |

---

## 9 · Open Questions & TODOs

1. Quantify XP curves – solicit community feedback.
2. Determine exact Section grammar for bold/label lines (Tree‑sitter).
3. Finalize persistence format for UoW commits (JSON vs. msgpack).

---

## 10 · Definition of Done Checklist

-

---

### **Let’s build!**

With this plan in place, work can proceed confidently, balancing Neovim responsiveness with clean architectural boundaries.  Each phase is incremental, heavily tested, and user‑visible—setting Zortex up for long‑term success.

