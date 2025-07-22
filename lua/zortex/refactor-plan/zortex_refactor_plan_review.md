# Review of Zortex Architecture Refactoring Plan

> _Document status: **Draft v0.1**_

---

## 1 · Overall Impression

The plan moves the project toward a **clean, layered architecture** that will dramatically lower coupling and improve testability.  The proposed layers (UI → Services → Domain → Data‑Access → Stores) and the cross‑cutting event bus and parser/cache are aligned with established patterns such as Hexagonal / Ports‑and‑Adapters.

However, some areas would benefit from **clearer success metrics, incremental migration paths, and deeper Neovim‑specific considerations**.

---

## 2 · Executive Summary Section

| ✅ Strengths | ⚠️ Opportunities for Improvement |
| --- | --- |
| • Clearly states high‑level goals (maintainability, cognitive load, feature velocity). | • Add **measurable outcomes** (e.g. "average PR review time < 2 days", "unit‑test coverage ≥ 70%") to track success. |
| • Identifies pain points users already feel. | • Include a **timeline / phases** to help contributors plan effort. |

### Suggestions
1. Add a _“Definition of Done”_ checklist for each goal.
2. Provide a visual roadmap (Gantt or simple bullets by month/sprint).

---

## 3 · Core Architecture Vision

| ✅ | ⚠️ |
| --- | --- |
| • Layered diagram helps newcomers grok boundaries. | • **Dependency Injection (DI)** strategy is implicit—spell out how services obtain repos/event‑bus (manual DI, service locator, or Lightweight IoC). |
| • Separates UI concerns from domain logic. | • **Circular‑dependency detection**: consider tooling or CI guard (e.g. `luacheck --deps`). |
| • Mentions Unit‑of‑Work for atomic changes. | • Clarify **transaction semantics**—what guarantees if part of a Unit fails? Rollback strategy? |

### Suggestions
* Adopt an **interface‑first policy**: define service/repository contracts up‑front (Lua tables with documented signatures) so refactors don’t break callers.
* Introduce **Domain Events** (pure‑data objects) distinct from UI events; handlers reside in application layer.

---

## 4 · File Parsing & Caching System

| ✅ | ⚠️ |
| --- | --- |
| • Lazy `Document` model reduces redundant I/O. | • **Invalidation trigger**: need a watcher (`vim.fs` + autocmd `BufWritePost`) to mark docs dirty when an edit occurs. |
| • Straightforward section‑index for random access. | • **Concurrency**: ensure thread‑safety if you later adopt async jobs (e.g. telescope background search). |
| • Considers stream parser for large files. | • Memory profile missing—estimate heap usage with 1k, 10k docs. |

### Suggestions
1. Wrap `DocumentManager:get_document` in a **memoize‑with‑TTL** helper so idle docs age out.
2. Evaluate using **Tree‑sitter incremental parsing** for higher fidelity and incremental updates.
3. Provide **public read‑only views**; mutations should flow through services to keep cache coherent.

---

## 5 · Event System Architecture

| ✅ | ⚠️ |
| --- | --- |
| • Simple synchronous bus is easy to debug. | • In Neovim, long handlers will block UI—consider **`vim.schedule_wrap`** or an async queue for heavy work. |
| • Middleware hooks (logging, validation). | • Add **wildcard / hierarchical topics** (e.g. `task:*`) for ergonomics. |
| • Returns unsubscribe closures. | • Provide **once‑only** & **debounce** helpers to avoid duplicate notifications. |

### Suggestions
* Define an **event naming convention** (`<noun>:<verb>` already good) and document payload shape with examples.
* Create **simulation tests** that fire sequences of events to measure latency and handler order.

---

## 6 · Service Layer Architecture

| ✅ | ⚠️ |
| --- | --- |
| • Centralizes business rules, hides store details. | • Needs an explicit **error boundary & retry** policy when coordinating multiple repos. |
| • Uses Unit‑of‑Work concept. | • Decide whether services are **stateful singletons** or **stateless factories** (important for tests). |

### Suggestions
1. Code‑gen **service skeletons** with Lunatest/Plenary unit tests stubbed—encourages test‑driven additions.
2. Consider **result objects** (`{ ok=true, value }` vs. `{ ok=false, err }`) instead of exceptions for predictable flows.

---

## 7 · Testing & CI

* Add a **Plenary‑based test harness**; track coverage with `luacov`.
* Use **GitHub Actions** matrix (stable Neovim vs. nightly) to prevent regressions.
* Seed the event bus with **property‑based tests** (luacheck‐luarocks `busted‑random‑lua`) to catch ordering bugs.

---

## 8 · Incremental Migration Strategy

1. **Strangle Fig**: wrap current global tables inside thin service‑compat facades.
2. Introduce new parsing cache but **toggle via feature flag** until stable.
3. Migrate one UI module at a time to the service layer; leverage bus adapters so old code still works.

---

## 9 · Areas Needing More Context / Files

| Wanted File | Why |
| ----------- | --- |
| `constants.lua` | Section/type enums & regexes—needed to validate parser plan. |
| `core/filesystem.lua` | Ensure DocumentManager I/O abstractions match FS helpers. |
| `stores/*` (besides `xp.lua`) | Gauge persistence patterns, detect race conditions. |
| Any **UI module** heavily using stores (e.g. `telescope.lua`) | Spot tight coupling to be refactored. |

If you can share these, feedback can be more concrete—especially around cache invalidation and event propagation.

---

## 10 · Conclusion

The refactor plan is **sound and ambitious**.  Tightening scope with measurable goals, concrete operational details (error handling, async behavior), and an incremental rollout roadmap will turn it from a _vision_ into an **actionable blueprint**.

---

### Next Steps
* [ ] Collect the additional files listed above (or confirm current designs).
* [ ] Prioritize which module to migrate first—recommend starting with **search module**, as its heavy cross‑cutting dependencies will validate the new event & parser infrastructure early.
* [ ] Align contributors on coding conventions (LuaDoc, styling) before code churn begins.

---

_End of Review_

