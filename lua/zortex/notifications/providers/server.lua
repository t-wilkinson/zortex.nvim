-- notifications/providers/server.lua - `zortex serve` notification API (POST /notify)
local base = require("zortex.notifications.providers.base")
local server = require("zortex.notifications.server")

local function user_id()
	return require("zortex.config").server.user_id or "default"
end

-- Wire format of one notification. Accepts the calendar's flat shape and the
-- manager's (fields under .options).
local function wire(n)
	local o = n.options or {}
	return {
		title = n.title,
		message = n.message,
		scheduled_time = n.scheduled_time or n.trigger_time or os.time(),
		priority = n.priority or o.priority or "default",
		tags = n.tags or o.tags or {},
		entry_id = n.entry_id or n.entry_text or o.entry_text,
		deduplication_key = n.deduplication_key or o.deduplication_key,
	}
end

local function send(title, message, options)
	options = options or {}
	server.request("POST", "/notify", {
		user_id = user_id(),
		operation = "notify",
		notification = wire({ title = title, message = message, options = options, scheduled_time = options.scheduled_time }),
	})
	return true, nil -- runs in the background
end

--- Replace the server's pending notifications with `notifications`.
--- cb(ok, result, err): result is the server's reply ({ added, updated, removed, unchanged, ... }).
local function sync_notifications(notifications, _, cb)
	if not server.enabled() then
		if cb then
			cb(false, nil, "server is not enabled")
		end
		return false, "server is not enabled"
	end
	local list = {}
	for _, n in ipairs(notifications) do
		list[#list + 1] = wire(n)
	end
	server.request("POST", "/notify", { user_id = user_id(), operation = "sync", notifications = list }, cb, { timeout = 30 })
	return true, nil
end

return base.create_provider("server", {
	send = send,
	sync = sync_notifications,
	wire = wire,
})
