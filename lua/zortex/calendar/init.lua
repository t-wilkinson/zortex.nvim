local M = {}

-- Load submodules
local ui = require("zortex.calendar.ui")
local utils = require("zortex.calendar.utils")
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
M.test_notification = notifications.test_notification

function M.setup()
	M.setup_notifications()

	local cmd = vim.api.nvim_create_user_command

	-- Digests
	cmd("ZortexDigestBuffer", M.show_digest_buffer, { desc = "Show today's digest in a buffer" })
	cmd("ZortexDigestNotify", M.show_today_digest, { desc = "Show today's digest as notification" })
	cmd("ZortexDigestDialog", M.show_today_digest_dialog, { desc = "Show today's digest as dialog (macOS)" })

	-- Testing Notifications
	cmd("ZortexTestNotify", M.test_notification, { desc = "Test notification system" })
	cmd("ZortexDebugNotify", M.debug_notifications, { desc = "Debug notification methods" })

	cmd("ZortexCalendar", M.open, { desc = "Browse Zortex calendar" })

	cmd("ZortexSetupNotifications", function()
		local count = M.setup_notifications()
		vim.notify(string.format("Scheduled %d notifications", count))
	end, {})
end

return M
