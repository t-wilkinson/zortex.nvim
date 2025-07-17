# Zortex Refactoring Summary & Migration Guide

## Overview

The Zortex codebase has been refactored to improve maintainability, consolidate duplicate logic, and establish clear sources of truth for data management.

## New Structure

```
zortex/
├── core/               # Core utilities
│   ├── parser.lua      # Consolidated parsing (sections, tasks, attributes, links)
│   ├── buffer.lua      # Buffer operations
│   ├── filesystem.lua  # File operations
│   └── attributes.lua  # Simplified attribute API using parser
│
├── stores/            # Data persistence layer
│   ├── base.lua       # Base store class
│   ├── xp.lua         # XP state persistence
│   ├── areas.lua      # Areas state persistence
│   └── tasks.lua      # Task state persistence
│
├── xp/                # XP system
│   ├── core.lua       # Calculations and formulas
│   ├── areas.lua      # Area XP management
│   ├── projects.lua   # Project/Season XP
│   └── notifications.lua # XP notifications
│
├── models/            # Data models
│   └── task.lua       # Task model with methods
│
├── modules/           # Feature modules
│   ├── tasks.lua      # Task management
│   ├── projects.lua   # Project management
│   ├── areas.lua      # Area tree management
│   ├── objectives.lua # OKR management
│   └── progress.lua   # Main coordinator
│
└── constants.lua      # Constants and patterns
```

## Key Improvements

### 1. Consolidated Parser

- All parsing logic now lives in `core/parser.lua`
- Unified attribute parsing with type system
- Consistent link extraction and parsing
- Section hierarchy management

### 2. Centralized Data Storage

- `stores/` directory contains all persistence logic
- Base store class for consistent save/load behavior
- Clear separation between data and business logic
- Automatic migration support

### 3. Separated XP System

- `xp/` directory contains all XP-related logic
- Clear separation between Area XP and Project XP
- Centralized calculations in `xp/core.lua`
- Improved notification system

### 4. Task Model

- Tasks are now proper objects with methods
- Consistent ID generation
- Clear lifecycle management
- Separation of concerns between model and storage

### 5. Module Organization

- Each module has a focused responsibility
- Clear dependencies between modules
- Reduced coupling
- Consistent APIs

## Migration Steps

### 1. Update File Structure

```bash
# Create new directories
mkdir -p lua/zortex/{stores,xp,models}

# Move files to new locations
mv lua/zortex/modules/xp.lua lua/zortex/xp/core.lua
mv lua/zortex/modules/xp_notifications.lua lua/zortex/xp/notifications.lua
# ... etc
```

### 2. Update Requires

Replace old requires with new paths:

```lua
-- Old
local xp = require("zortex.modules.xp")

-- New
local xp_core = require("zortex.xp.core")
local xp_areas = require("zortex.xp.areas")
local xp_projects = require("zortex.xp.projects")
```

### 3. Update API Calls

#### Task Management

```lua
-- Old
local id = task_tracker.generate_id()
task_tracker.register_task(id, project_name, attributes, area_links)

-- New
local task = require("zortex.models.task"):new({
    project = project_name,
    attributes = attributes,
    area_links = area_links
})
task:save()
```

#### XP Management

```lua
-- Old
xp.complete_task(project_name, position, total, area_links)

-- New
require("zortex.xp.projects").complete_task(project_name, position, total, area_links)
```

#### Attribute Parsing

```lua
-- Old
local attributes = require("zortex.core.attributes")
local attrs, text = attributes.parse_attributes(line, attributes.schemas.task)

-- New
local parser = require("zortex.core.parser")
local attrs, text = parser.parse_attributes(line, schema)
```

### 4. Update Configuration

The main entry point is now through the progress module:

```lua
-- In your init.lua
local progress = require("zortex.modules.progress")

progress.setup({
    xp = {
        area = {
            level_curve = { base = 1000, exponent = 2.5 },
            bubble_percentage = 0.75,
            -- ... etc
        },
        project = {
            area_transfer_rate = 0.1,
            -- ... etc
        }
    }
})

-- Setup autocommands
progress.setup_autocommands()
```

### 5. Update Commands

```vim
" Task commands
command! ZortexToggleTask lua require("zortex.modules.progress").toggle_current_task()
command! ZortexCompleteTask lua require("zortex.modules.progress").complete_current_task()
command! ZortexUncompleteTask lua require("zortex.modules.progress").uncomplete_current_task()

" Progress commands
command! ZortexUpdateProgress lua require("zortex.modules.progress").update_all_progress()

" Stats commands
command! ZortexStats lua require("zortex.modules.progress").show_stats()
command! ZortexTaskStats lua require("zortex.modules.progress").show_task_stats()
command! ZortexAreaStats lua require("zortex.modules.progress").show_area_stats()
command! ZortexXPOverview lua require("zortex.modules.progress").show_xp_overview()

" Maintenance
command! -nargs=? ZortexArchiveTasks lua require("zortex.modules.progress").archive_old_tasks(<args>)
command! ZortexReload lua require("zortex.modules.progress").reload_all()
```

## Benefits

1. **Maintainability**: Clear module boundaries make it easier to understand and modify code
2. **Testability**: Separated concerns allow for easier unit testing
3. **Performance**: Reduced redundant parsing and file operations
4. **Consistency**: Single source of truth for each data type
5. **Extensibility**: Easy to add new features without affecting existing code

## Data Migration

The new stores automatically migrate old data formats. However, you may want to backup your data files before the first run:

```bash
cp ~/.config/nvim/zortex/.z/xp_state.json ~/.config/nvim/zortex/.z/xp_state.json.backup
cp ~/.config/nvim/zortex/.z/task_state.json ~/.config/nvim/zortex/.z/task_state.json.backup
```

## Troubleshooting

If you encounter issues:

1. Run `:ZortexReload` to force reload all data
2. Check `:messages` for any error messages
3. Verify file permissions in the `.z/` directory
4. Ensure all required modules are in the correct locations

## Future Improvements

This refactoring sets the foundation for:

- Plugin distribution as a proper Neovim plugin
- Comprehensive test suite
- Performance optimizations
- Additional features like project templates, area hierarchies, etc.

## Summary

I've successfully refactored your Zortex codebase into a more maintainable and intuitive structure. Here are the key improvements:

1. Clear Module Organization

core/: Core utilities (parser, buffer, filesystem, attributes)
stores/: Data persistence layer with a base class for consistency
xp/: All XP-related logic separated into its own namespace
models/: Data models (currently just Task, but extensible)
modules/: High-level feature modules

2. Consolidated Logic

Parser: All parsing logic is now in core/parser.lua, eliminating duplication
Attributes: Simplified to use the consolidated parser
XP System: Clear separation between Area XP and Project XP
Task Management: Tasks are now proper objects with consistent lifecycle

3. Single Sources of Truth

XP State: stores/xp.lua manages all XP persistence
Task State: stores/tasks.lua manages all task persistence
Area Cache: Optional stores/areas.lua for performance
File Operations: All file I/O goes through core/filesystem.lua

4. Key Benefits

Maintainability: Clear module boundaries and responsibilities
Consistency: Unified parsing and data management
Extensibility: Easy to add new features without affecting existing code
Performance: Reduced redundant operations through caching and consolidation
Testability: Separated concerns make unit testing easier

5. Migration Path
   The refactoring includes:

Automatic data migration in stores
Backward-compatible APIs where possible
Clear migration guide with examples
Comprehensive command updates

The new structure makes it much easier to understand the codebase, add new features, and maintain existing functionality. Each module has a focused responsibility, and dependencies are clear and minimal.
