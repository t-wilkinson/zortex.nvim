# **Zortex: Final Architecture & Implementation Plan**

## **1\. Executive Summary**

This document presents the definitive refactoring plan for the Zortex Neovim plugin. The current architecture suffers from tight coupling, scattered business logic, and synchronous operations that create cognitive overhead and risk UI latency. This has made debugging, maintenance, and feature development unnecessarily complex, particularly within the XP system.  
The solution is a transition to a **decoupled, asynchronous, and service-oriented architecture** that is fundamentally aligned with Neovim's event loop and performance expectations. By treating the Vim buffer as the primary source of truth and leveraging an asynchronous event bus, we will resolve the core pain points while building a robust foundation for future growth.  
**The goals of this refactor are to:**

1. **Reduce Cognitive Load:** Create clear boundaries and responsibilities for each module.  
2. **Eliminate Circular Dependencies:** Decouple all major systems (Tasks, Projects, XP, Search) from one another.  
3. **Maximize Performance:** Ensure a non-blocking user experience by embracing asynchronicity.  
4. **Improve Testability & Maintainability:** Enable isolated unit and integration testing for all business logic.

## **2\. Core Architectural Principles**

All new development and refactoring must adhere to these principles:

* **The Buffer is the Source of Truth:** For any active file, the content in the Neovim buffer—including unsaved changes—is the canonical data source for all real-time operations. The file on disk is for persistence, not for live queries.  
* **Asynchronous by Default:** Any I/O operation (file reads/writes) or potentially long-running computation MUST be executed asynchronously using vim.schedule() to avoid blocking the main UI thread. Synchronous operations are the exception and must be justified.  
* **Decoupling via Events:** Modules and services MUST NOT have direct dependencies on each other. Communication must occur through a central, asynchronous event bus. For example, the TaskService does not know the XPService exists; it simply emits a TASK\_COMPLETED event.  
* **State is Managed, Not Inferred:** The plugin will maintain a reliable in-memory state (the "model"). Changes flow from user actions to this model, which then triggers events that update the buffer (the "view") and persist to disk. We will not re-parse the buffer on every single action.

## **3\. The New Architecture: System by System**

### **A. The Foundation: DocumentManager & Event Bus**

#### **I. DocumentManager: The Centralized Parser & Cache**

This component solves the problem of redundant parsing and provides a consistent, structured view of all Zortex files.

* **Responsibilities:**  
  * Maintain an in-memory cache of parsed Zortex documents (as Abstract Syntax Trees \- ASTs).  
  * Provide a single, authoritative source for accessing file structure (sections, tasks, links).  
  * Intelligently update its cache based on Neovim buffer events.  
* **Neovim-Aware Cache Invalidation:**  
  * **BufReadPost, BufEnter:** Load/parse the document from buffer content and populate the cache.  
  * **TextChanged, TextChangedI:** Mark the cached document as "dirty." The cache is fully re-parsed from the buffer's content. This operation will be debounced using vim.defer\_fn() to prevent thrashing during rapid typing.  
  * **BufWritePost:** The file and buffer are in sync. The cache can be marked as "clean."  
  * **BufWipeout:** The document is evicted from the cache to prevent memory leaks.  
* **Parsing Strategy:**  
  * **Initial:** The existing line-based parser will be used to quickly build the DocumentManager.  
  * **Future:** Offload parsing to a **Tree-sitter** grammar for Zortex files. This will provide superior performance, incremental parsing, and more robust error handling. This is a potential future enhancement, not a blocker for the initial refactor.

#### **II. EventBus: The Central Nervous System**

This component enforces decoupling and enables our "asynchronous by default" principle.

* **Design:**  
  * A singleton object that manages event subscriptions and emissions.  
  * Provides two primary subscription methods:  
    * EventBus:on\_async(event, handler): (Default) Wraps the handler in vim.schedule(). The emit call returns immediately, and the handler executes on a future tick of the event loop.  
    * EventBus:on\_sync(event, handler): For handlers that are guaranteed to be instantaneous (e.g., updating a single value in an in-memory table). To be used sparingly.  
* **Core Events Defined:**  
  * DOCUMENT\_CHANGED: Emitted by the DocumentManager when a buffer is modified.  
  * TASK\_CREATED, TASK\_UPDATED, TASK\_COMPLETED: Emitted by the TaskService.  
  * PROJECT\_CREATED, PROJECT\_UPDATED, PROJECT\_COMPLETED: Emitted by the ProjectService.  
  * XP\_GAINED, LEVEL\_UP: Emitted by the XPService.  
  * SEARCH\_INDEX\_DIRTY: Emitted when a document changes, signaling the search indexer to update.

### **B. The Logic: Services & Persistence**

#### **III. Service Layer**

Services contain all business logic. They are stateless and their methods are called by the UI layer (commands, keymaps).

* **TaskService:** Manages the lifecycle of tasks.  
  * complete\_task(id): Updates the task's state in memory and emits TASK\_COMPLETED with the task data as a payload.  
* **ProjectService:** Manages projects and their progress.  
  * Listens for TASK\_COMPLETED events.  
  * When a relevant task is completed, it updates the corresponding project's progress in memory and emits PROJECT\_UPDATED.  
* **XPService:** (The solution to the XP pain point)  
  * **Completely isolated.** It knows nothing about tasks or projects.  
  * Listens for TASK\_COMPLETED and PROJECT\_COMPLETED events.  
  * Calculates XP based on the event payload (e.g., task attributes, project size).  
  * Updates its internal XP state and emits XP\_GAINED.  
* **SearchService:**  
  * Listens for DOCUMENT\_CHANGED and BufWritePost events.  
  * Triggers background indexing of the changed document's content.  
  * Provides a single search(query) function that queries the pre-built index.

#### **IV. Persistence: Batched & Asynchronous**

This directly addresses the concern of how and when to save data.

* **State Management:** The primary state (tasks, projects, XP totals) is held in Lua tables within the respective stores. These stores are the single source of truth for the plugin's internal state.  
* **Unit of Work (UoW) / Batched Persistence:**  
  1. When a service modifies data, it marks the relevant store as "dirty" (e.g., xp\_store.dirty \= true).  
  2. No file I/O happens immediately.  
  3. A central persistence manager listens for BufWritePost and VimLeave autocommands.  
  4. On these triggers, it checks for any dirty stores and calls their save() methods, which write the data to disk asynchronously.  
  * This approach batches all in-memory changes from a user session into a single, non-blocking write operation, ensuring maximum responsiveness.

### **C. The Periphery: Search & Links**

#### **V. Search Index**

The search index must be fast and not block the UI.

* **Source:** The index is built from the content provided by the DocumentManager.  
* **Indexing:** Indexing is a background process. The SearchService listens for events indicating a document has changed (SEARCH\_INDEX\_DIRTY) and schedules a low-priority background job to update the index for that file.  
* **Technology:** An inverted index implemented in Lua is sufficient for the core files. This avoids external dependencies.

#### **VI. Link Resolver**

The link resolver can be integrated cleanly.

* **Integration:** The DocumentManager, by parsing files into an AST, will naturally identify all sections and their unique identifiers.  
* **Functionality:** The link\_resolver becomes a simple service that queries the DocumentManager's cached data. It can quickly find the file and line number for any link target (\[Link\]) without needing to parse files itself. This makes link resolution instantaneous.

## **4\. Implementation Roadmap**

This refactor will be executed in phases to ensure stability.

#### **Phase 1: The Foundation (Weeks 1-2)**

*Goal: Build the core infrastructure. No user-facing changes.*

1. **Implement the EventBus:** Create the core/event\_bus.lua module with on\_async and on\_sync methods.  
2. **Implement the DocumentManager:** Create core/document\_manager.lua. Hook it into the Neovim autocommands for cache management. Start with the existing parser.  
3. **Establish Testing Harness:** Set up plenary.busted for integration testing. Write tests that simulate buffer changes and verify the DocumentManager and EventBus behave correctly.

#### **Phase 2: Isolate the XP System (Weeks 3-4)**

*Goal: Decouple the most complex module.*

1. **Create XPService and XPStore:** Move all XP calculation and state logic into these new modules.  
2. **Subscribe to Events:** The XPService will subscribe to TASK\_COMPLETED (initially a placeholder event).  
3. **Strangler Fig Pattern:** In the old tasks.lua and projects.lua, replace direct calls to XP functions with a simple EventBus:emit("TASK\_COMPLETED", ...) call.  
4. **Verify:** Confirm that completing a task still correctly awards XP, but now through the decoupled event system.

#### **Phase 3: Migrate Core Services (Weeks 5-6)**

*Goal: Move all business logic into the new service architecture.*

1. **Implement TaskService, ProjectService, and their stores.**  
2. **Connect UI to Services:** Refactor keymaps and user commands to call methods on the new services instead of the old module functions.  
3. **Implement Batched Persistence:** Create the persistence manager that saves dirty stores on BufWritePost.

#### **Phase 4: Cleanup & Finalization (Week 7\)**

*Goal: Remove all legacy code.*

1. Delete the old, now-unused functions from modules/\*.lua.  
2. Remove the compatibility layers.  
3. Write comprehensive documentation for the new architecture.  
4. Benchmark key interactions (task completion, search) to ensure performance goals are met.