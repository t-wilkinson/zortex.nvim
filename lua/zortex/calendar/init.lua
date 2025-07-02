local M = {}

-- Load submodules
local ui = require("zortex.calendar.ui")
local data = require("zortex.calendar.data")
local projects = require("zortex.calendar.projects")
local telescope = require("zortex.calendar.telescope")

-- Re-export main functions
M.open = ui.open
M.close = ui.close
M.add_entry_interactive = ui.add_entry_interactive
M.go_to_date = ui.go_to_date
M.set_date = ui.set_date

-- Data functions
M.load = data.load
M.save = data.save
M.add_entry = data.add_entry
M.get_entries_for_date = data.get_entries_for_date
M.setup_notifications = data.setup_notifications
M.show_today_digest = data.show_today_digest

-- Projects functions
M.load_projects = projects.load
M.get_tasks_for_date = projects.get_tasks_for_date
M.get_all_projects = projects.get_all_projects

-- Telescope functions
M.telescope_calendar = telescope.telescope_calendar
M.telescope_digest = telescope.telescope_digest

return M
