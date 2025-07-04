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

-- Utils functions
M.load = utils.load
M.save = utils.save
M.add_entry = utils.add_entry
M.get_entries_for_date = utils.get_entries_for_date

-- Notifications
M.setup_notifications = notifications.setup_notifications
M.show_today_digest = notifications.show_today_digest
M.show_digest_buffer = notifications.show_digest_buffer
M.debug_notifications = notifications.debug_notifications
M.show_today_digest_dialog = notifications.show_today_digest_dialog
M.setup_help = notifications.setup_help
M.test_notification = notifications.test_notification

-- Projects functions
M.load_projects = projects.load
M.get_tasks_for_date = projects.get_tasks_for_date
M.get_all_projects = projects.get_all_projects

-- Telescope functions
M.telescope_calendar = telescope.telescope_calendar
M.telescope_projects = telescope.telescope_projects
M.telescope_today_digest = telescope.telescope_today_digest

function M.setup()
	M.setup_notifications()

	local cmd = vim.api.nvim_create_user_command

	-- Digests
	cmd("ZortexTodayDigest", M.telescope_today_digest, { desc = "Show today's digest in Telescope" })
	cmd("ZortexDigest", M.show_digest_buffer, { desc = "Show today's digest in a buffer" })
	cmd("ZortexDigestNotify", M.show_today_digest, { desc = "Show today's digest as notification" })
	cmd("ZortexDigestDialog", M.show_today_digest_dialog, { desc = "Show today's digest as dialog (macOS)" })

	-- Testing Notifications
	cmd("ZortexTestNotify", M.test_notification, { desc = "Test notification system" })
	cmd("ZortexDebugNotify", M.debug_notifications, { desc = "Debug notification methods" })

	cmd("ZortexCalendarSearch", M.telescope_calendar, { desc = "Browse calendar chronologically" })
	cmd("ZortexCalendar", M.open, { desc = "Browse Zortex calendar" })
	cmd("ZortexProjects", M.telescope_projects, { desc = "Search projects with priority sorting" })

	cmd("ZortexSetupNotifications", function()
		local count = M.setup_notifications()
		vim.notify(string.format("Scheduled %d notifications", count))
	end, {})
end

return M
