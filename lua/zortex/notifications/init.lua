-- notifications/init.lua - Notifications, through `zortex serve`
--
-- The server (Config.server) does the sending: the calendar's notifications
-- (notifications/calendar, synced when calendar.zortex is saved) and the
-- pomodoro's phase changes (notifications/pomodoro) go out through ntfy when
-- they are due. Neovim asks the server every `poll_seconds` for the alerts it
-- raised since (calendar, pomodoro, the web app's timers and alarms) and
-- shows each one in the editor.
--
--   local n = require("zortex.notifications")
--   n.sync_now(force)       -- :ZortexNotifications sync [force]
--   n.show_list()           -- :ZortexNotifications list
--   n.send(title, message)  -- :ZortexNotifications send <title> <message>
local M = {}

local server = require("zortex.notifications.server")
local calendar = require("zortex.notifications.calendar")
local pomodoro = require("zortex.notifications.pomodoro")

M.calendar = calendar
M.pomodoro = pomodoro

local cfg = {}

local NO_SERVER = "Notifications need `zortex serve` (Config.server)"

local function say(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

-- =============================================================================
-- Alerts from the server, shown in Neovim
-- =============================================================================

local alerts = { seq = nil, timer = nil, busy = false }

local ICONS = { calendar = "📅", pomodoro = "🍅", clock = "⏰" }

--- Show the alerts in `body` ({ seq, alerts = { { kind, title, message } } })
--- and remember where the list is. The first answer only sets the position.
function M.take_alerts(body)
	if type(body) ~= "table" or type(body.seq) ~= "number" then
		return
	end
	local first = alerts.seq == nil or body.seq < alerts.seq -- a restarted server starts over
	alerts.seq = body.seq
	if first then
		return
	end
	for _, a in ipairs(body.alerts or {}) do
		local text = (ICONS[a.kind] or "🔔") .. " " .. (a.title or "")
		if a.message and a.message ~= "" then
			text = text .. "\n" .. a.message
		end
		vim.notify(text, vim.log.levels.WARN, { title = "Zortex" })
	end
end

local function poll()
	if alerts.busy then
		return
	end
	alerts.busy = true
	local path = alerts.seq and ("/api/alerts?after=" .. alerts.seq) or "/api/alerts"
	server.request("GET", path, nil, function(ok, body)
		alerts.busy = false
		if ok then
			M.take_alerts(body)
		end
	end, { timeout = 5 })
end

local function start_alerts()
	if alerts.timer or cfg.alerts == false then
		return
	end
	local every = math.max(5, tonumber(cfg.poll_seconds) or 15) * 1000
	alerts.timer = vim.uv.new_timer()
	alerts.timer:start(100, every, vim.schedule_wrap(poll))
end

local function stop_alerts()
	if alerts.timer then
		alerts.timer:stop()
		alerts.timer:close()
		alerts.timer = nil
	end
end

-- =============================================================================
-- Commands
-- =============================================================================

--- :ZortexNotifications sync [force]
function M.sync_now(force)
	calendar.sync({
		force = force,
		on_done = function(msg)
			if msg:match("unchanged") then
				msg = msg .. "; nothing sent (`:ZortexNotifications sync force` resends)"
			end
			say(msg)
		end,
	})
end

--- :ZortexNotifications list: what the server will send, in a split.
function M.show_list()
	if not server.enabled() then
		return say(NO_SERVER, vim.log.levels.WARN)
	end
	local ok, list, err = server.pending()
	if not ok then
		return say("Server unreachable: " .. tostring(err), vim.log.levels.WARN)
	end
	if #list == 0 then
		return say("No notifications waiting to be sent")
	end
	local lines = { "Notifications the server will send:", "" }
	for _, n in ipairs(list) do
		lines[#lines + 1] = string.format("%s  %s: %s", os.date("%b %d %H:%M", n.scheduled_time), n.title or "", (n.message or ""):sub(1, 60))
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

--- :ZortexNotifications send <title> <message>: one now, through the server.
function M.send(title, message)
	if not server.enabled() then
		return say(NO_SERVER, vim.log.levels.WARN)
	end
	if not title or title == "" then
		return say("Usage: :ZortexNotifications send <title> <message>", vim.log.levels.WARN)
	end
	server.send_now(title, message or "", function(ok, _, err)
		if not ok then
			say("Server unreachable: " .. tostring(err), vim.log.levels.WARN)
		end
	end)
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	cfg = opts or {}
	pomodoro.setup()
	if cfg.enabled == false then
		return
	end
	calendar.setup(cfg)
	if server.enabled() then
		start_alerts()
	end

	local group = vim.api.nvim_create_augroup("ZortexNotifications", { clear = true })
	-- the calendar's notifications follow it
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*calendar.zortex",
		callback = function()
			vim.defer_fn(function()
				calendar.sync({ silent = true })
			end, 100)
		end,
		desc = "Zortex: send the calendar's notifications to the server",
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			stop_alerts()
			pomodoro.cleanup()
		end,
	})
end

return M
