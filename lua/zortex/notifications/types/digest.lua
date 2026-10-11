-- notifications/types/digest.lua - When to send the daily digest email
--
-- The content comes from services/digest (M.email); this module schedules
-- and sends it through the notification manager.
local M = {}

local store = require("zortex.stores.notifications")

local cfg = {}

local function digest()
	return require("zortex.services.digest")
end

-- Send the digest email now
function M.send_digest(options)
	options = options or {}
	local days = options.days_ahead or cfg.days_ahead or 7
	local manager = require("zortex.notifications.manager")
	local subject, text, html = digest().email(days)
	if not subject then
		if options.force then
			manager.send_notification(
				"Zortex Daily Digest - No Events",
				"You have no calendar entries for the next " .. days .. " days.",
				{ type = "digest", providers = cfg.providers or { "ses" } }
			)
		end
		return false, "No calendar entries to include in digest"
	end
	local results = manager.send_notification(subject, text, {
		type = "digest",
		providers = cfg.providers or { "ses" },
		format = "digest",
		html = html,
		domain = cfg.domain,
	})
	for _, result in pairs(type(results) == "table" and results or {}) do
		if type(result) == "table" and result.success then
			store.update_digest_state({ last_digest_sent = os.time() })
			return true, "Daily digest sent"
		end
	end
	return false, "Failed to send daily digest"
end

-- Due: 20+ hours since the last one, within two hours after send_hour
local function should_send_digest()
	local last_sent = store.get_digest_state().last_digest_sent
	if not last_sent then
		return true
	end
	if (os.time() - last_sent) / 3600 < 20 then
		return false
	end
	local hour = tonumber(os.date("%H"))
	local send_hour = cfg.send_hour or 7
	return hour >= send_hour and hour < send_hour + 2
end

function M.schedule_auto_digest()
	if not cfg.auto_send then
		return
	end
	local timer = vim.loop.new_timer()
	timer:start(
		0,
		(cfg.check_interval_minutes or 60) * 60 * 1000,
		vim.schedule_wrap(function()
			if should_send_digest() then
				M.send_digest({ days_ahead = cfg.days_ahead })
			end
		end)
	)
	return timer
end

function M.setup(opts)
	cfg = opts or {}
	if cfg.auto_send then
		M.schedule_auto_digest()
	end
end

function M.send_now(days)
	return M.send_digest({ days_ahead = days or cfg.days_ahead, force = true })
end

-- Show the email's text version in a split
function M.preview(days)
	local subject, text = digest().email(days or cfg.days_ahead)
	if not subject then
		vim.notify("No calendar entries for digest", vim.log.levels.INFO)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(subject .. "\n\n" .. text, "\n"))
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	pcall(vim.api.nvim_buf_set_name, buf, "Daily Digest Preview")
	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

return M
