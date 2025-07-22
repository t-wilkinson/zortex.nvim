# Zortex Refactor Plan · **Vim‑Plugin Perspective**

> _Draft v0.1 — Focused on Neovim/LuaJIT realities_

---

## 1 · Top‑Level Assessment

| ✅ What Works Well | ⚠️ Potential Issues in Vim Context |
| --- | --- |
| **Layer isolation** (UI → Services → Domain → Stores) naturally aligns with Neovim’s modular plugin expectations—facilitates lazy‑loading. | Heavy reliance on **synchronous Lua I/O** (e.g. `io.open`, `vim.loop.read_file`) will block the main thread; Neovim’s UI freezes if any op > 16 ms. |
| Event‑bus concept fits Neovim’s autocommand idioms. | No plan for **coroutine / jobcontrol integration**—essential for non‑blocking background tasks (search indexing, XP recompute). |
| Parsing cache avoids repeat disk scans. | Lua tables can balloon quickly under LuaJIT; need hard numbers to avoid the notorious **“OOM on large buffers”** issue when indexing thousands of notes. |

---

## 2 · LuaJIT Performance & Memory

### Strengths
* Use of **pure‑Lua data structures** keeps dependencies minimal—good for plugin distribution.
* Unit‑of‑Work idea can reduce repeated table mutations if batched.

### Flaws / Risks
* **Table churn** in events (creating `{}` for each emit) drives allocations → traces GC pauses. Consider an **object pool** for hot paths.
* Parser walks lines with `string.match`—fine, but avoid `%f[` or frontier patterns; they deopt JIT funnels.
* Missing **`jit.off` hotspots**: recursive parse of deeply nested sections likely hits trace depth limits.

### Recommendations
1. Profile with `require('plenary.profile')` on 1k+ files; target < 50 MB RSS after warm cache.
2. Convert immutable domain objects to **struct‑like tables with numeric keys** or cdata FFI structs if extreme scale is required.

---

## 3 · Async & Job Control

| Design Component | Current State | Vim‑Friendly Improvement |
| --- | --- | --- |
| **Event Bus** | Synchronous callbacks. | Provide **`emit_async(topic, payload, cb)`** using `vim.loop.new_async` or `vim.system` (0.10) so handlers can yield without blocking UI. |
| **Search Indexer** | TBD | Offload to **`jobstart`** running `ripgrep` / Lua worker; stream results into channel to populate cache.
| **Long XP Recompute** | In‑process loop. | Wrap in `vim.schedule_wrap` to defer until after redraw; show mini‑progress via extmarks.

---

## 4 · Neovim API Usage

### Positives
* Plans to consolidate extmark decoration in a single module—reduces namespace clashes.
* Clear intent to use `vim.fs` wrappers for portability.

### Concerns
* UI layer mentions “Component library” but not **popup/buffer management** strategy. Rogue floating windows are common perf pitfall (too many extmarks → redraw lag).
* Needs **dedicated namespace per feature** (links, tasks, calendar) to avoid highlight leaks on `nvim_buf_clear_namespace`.
* Ensure cursor‑freeze issues solved by placing heavy extmark updates inside `vim.defer_fn` with chunked slices (100 rows per tick).

---

## 5 · Parser & Treesitter

| Aspect | Observation | Advice |
| --- | --- | --- |
| Current Parser | Custom line regexes in `parser.lua`. | Good for bootstrapping, but Tree‑sitter offers incremental reparsing—ideal for live editing. |
| File Size | Plan to stream large docs. | **Tree‑sitter’s `parse_range`** could replace manual diff detection; lowers memory if you reuse parser object. |
| Error Handling | No recovery spec. | Use TS **error nodes** to skip malformed syntax instead of crashing.

---

## 6 · Testing Strategy (Plugin‑Specific)

* Adopt **MiniTest** or **Busted + Plenary** with `helpers.new_buffer` to simulate edits; ensures parser & event system handle actual buffer changes, not just file paths.
* Add **screen‑based tests** via `stylua` snapshots for UI modules—catch extmark drift bugs early.

---

## 7 · Distribution & Lazy Loading

| Module | Lazy‑load Trigger | Note |
| --- | --- | --- |
| Parser/Cache | `BufReadPre *.zortex` | Must init before syntax attach. |
| UI Commands | `CmdUndefined Zortex*` | Keeps startup < 20 ms. |
| XP System | `User ZortexTaskToggled` | Avoids background loops until needed.

Implement with **`lazy.nvim` opts** (or `folke/lazy.nvim`) to take advantage of your existing config.

---

## 8 · Migration Checklist (Vim‑Spec)

1. **Refactor Store Access**: Replace global stores with **module‑local upvalues**; expose via `require('zortex.stores').with_readonly(fn)` to prevent accidental writes.
2. **Introduce Async Safe‑Mutation Queue**: Use `vim.queue_on_channel()` like Patternfly plugin does—ensures writes occur after buffer events settle.
3. **Document Compat Matrix**: Maintain tested versions (NVIM 0.9 & 0.10 nightly). Guard 0.10‑only APIs (e.g. `vim.system`) via feature detection.

---

## 9 · Additional Files Needed for Deep Dive

* `ui/*` modules (calendar, links) to audit extmark logic.
* `stores/*.lua` besides `xp.lua` to evaluate serialization.
* Build scripts (`lazy-lock.json`, `healthcheck.lua`) to ensure consumers get proper diagnostics.

---

## 10 · Verdict

The architectural vision is **strong** but must be grounded in **Neovim runtime realities**: non‑blocking execution, LuaJIT memory quirks, and UI redraw constraints. Address the highlighted async, memory, and namespace issues early to avoid painful rewrites after adoption.

---

### Immediate Actions
* [ ] Prototype an **async search indexer** using `vim.system({ 'rg', ... })` and measure UI impact.
* [ ] Add **extmark throughput benchmark**: render 5k tasks and profile fps with `:checkhealth`. Aim for > 45 fps on modest hardware.
* [ ] Share the additional code sections so we can validate event flow and propose code‑level patches.

---

_End of Vim‑Plugin Focused Review_

