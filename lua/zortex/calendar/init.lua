local M = {}

-- Load submodules
local ui = require("zortex.calendar.ui")
local utils = require("zortex.calendar.utils")
local projects = require("zortex.calendar.projects")
local telescope = require("zortex.calendar.telescope")
local notifications = require("zortex.calendar.notifications")

-- Re-export main functions
M.open = ui.open
M.close = ui.close
M.add_entry_interactive = ui.add_entry_interactive
M.go_to_date = ui.go_to_date
M.set_date = ui.set_date

-- Utils functions
M.load = utils.load
M.save = utils.save
M.add_entry = utils.add_entry
M.get_entries_for_date = utils.get_entries_for_date

-- Notifications
M.setup_notifications = notifications.setup_notifications
M.show_today_digest = notifications.show_today_digest

-- Projects functions
M.load_projects = projects.load
M.get_tasks_for_date = projects.get_tasks_for_date
M.get_all_projects = projects.get_all_projects

-- Telescope functions
M.telescope_calendar = telescope.telescope_calendar
M.telescope_digest = telescope.telescope_digest

return M
