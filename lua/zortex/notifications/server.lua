-- notifications/server.lua - Talking to `zortex serve` (Config.server)
--
-- The server (app/, `zortex serve -data DIR`) keeps the calendar's scheduled
-- notifications and the pomodoro clock, sends both through ntfy, and lists
-- the alerts it raised for Neovim to show.
--
--   local server = require("zortex.notifications.server")
--   server.enabled()
--   server.request("POST", "/notify", { ... }, function(ok, body, err) end)
--   server.request_sync("GET", "/api/pomodoro")   -- blocking, short timeout
--   server.send_calendar(list, cb)                -- replace the pending set
--   server.send_now(title, message, cb)           -- one notification, now
local M = {}

local function cfg()
	return require("zortex.config").server or {}
end

function M.enabled()
	local c = cfg()
	return c.enabled == true and type(c.api_endpoint) == "string" and c.api_endpoint ~= ""
end

local function build_cmd(method, path, body, timeout)
	local c = cfg()
	local cmd = {
		"curl",
		"-sS",
		"--connect-timeout",
		"3",
		"--max-time",
		tostring(timeout or 15),
		"-X",
		method,
		"-H",
		"Accept: application/json",
		-- JSON body: also what the server requires for pomodoro actions
		"-H",
		"Content-Type: application/json",
		"-w",
		"\n%{http_code}",
	}
	if c.api_key and c.api_key ~= "" then
		vim.list_extend(cmd, { "-H", "X-API-Key: " .. c.api_key })
	end
	if body ~= nil then
		vim.list_extend(cmd, { "--data-binary", "@-" })
	end
	cmd[#cmd + 1] = c.api_endpoint:gsub("/+$", "") .. path
	return cmd
end

-- curl output "<body>\n<status>" -> ok, decoded body, error
local function parse(code, out, stderr)
	if code ~= 0 then
		return false, nil, vim.trim(stderr or "") ~= "" and vim.trim(stderr) or ("curl exited with " .. code)
	end
	local text, status = (out or ""):match("^(.*)\n(%d+)%s*$")
	status = tonumber(status)
	local decoded
	if text and text ~= "" then
		local ok, val = pcall(vim.json.decode, text)
		decoded = ok and val or nil
	end
	if not status or status >= 400 then
		local msg = type(decoded) == "table" and decoded.error or ("HTTP " .. tostring(status))
		return false, decoded, msg
	end
	return true, decoded, nil
end

--- Asynchronous request. cb(ok, body, err) runs on the main loop.
function M.request(method, path, body, cb, opts)
	opts = opts or {}
	if not M.enabled() then
		if cb then
			vim.schedule(function()
				cb(false, nil, "server is not enabled (Config.server)")
			end)
		end
		return
	end
	local input = body ~= nil and vim.json.encode(body) or nil
	local cmd = build_cmd(method, path, body, opts.timeout)
	if vim.system then
		vim.system(cmd, { text = true, stdin = input }, function(res)
			local ok, decoded, err = parse(res.code, res.stdout, res.stderr)
			if cb then
				vim.schedule(function()
					cb(ok, decoded, err)
				end)
			end
		end)
		return
	end
	local stdout, stderr = {}, {}
	local job = vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			stdout = data
		end,
		on_stderr = function(_, data)
			stderr = data
		end,
		on_exit = function(_, code)
			local ok, decoded, err = parse(code, table.concat(stdout, "\n"), table.concat(stderr, "\n"))
			if cb then
				vim.schedule(function()
					cb(ok, decoded, err)
				end)
			end
		end,
	})
	if job > 0 and input then
		vim.fn.chansend(job, input)
	end
	if job > 0 then
		vim.fn.chanclose(job, "stdin")
	end
end

--- Blocking request (for commands that print a result). Returns ok, body, err.
function M.request_sync(method, path, body, timeout)
	if not M.enabled() then
		return false, nil, "server is not enabled (Config.server)"
	end
	local input = body ~= nil and vim.json.encode(body) or nil
	local cmd = build_cmd(method, path, body, timeout or 5)
	if vim.system then
		local res = vim.system(cmd, { text = true, stdin = input }):wait()
		return parse(res.code, res.stdout, res.stderr)
	end
	local out = vim.fn.system(cmd, input or "")
	return parse(vim.v.shell_error, out, "")
end

-- =============================================================================
-- Notifications
-- =============================================================================

local function user_id()
	return cfg().user_id or "default"
end

-- One notification as the server takes it (POST /notify)
local function wire(n)
	return {
		title = n.title,
		message = n.message,
		scheduled_time = n.scheduled_time or n.trigger_time or os.time(),
		priority = n.priority or "default",
		tags = n.tags or {},
		entry_id = n.entry_id or n.entry_text,
		deduplication_key = n.deduplication_key,
	}
end
M.wire = wire

--- Replace the server's pending calendar notifications with `list`.
--- cb(ok, result, err): result is { added, updated, removed, unchanged, ... }.
function M.send_calendar(list, cb)
	local out = {}
	for _, n in ipairs(list) do
		out[#out + 1] = wire(n)
	end
	M.request("POST", "/notify", { user_id = user_id(), operation = "sync", notifications = out }, cb, { timeout = 30 })
end

--- A notification now: the server sends it through ntfy (and it comes back
--- to Neovim as an alert).
function M.send_now(title, message, cb)
	M.request("POST", "/notify", {
		user_id = user_id(),
		operation = "notify",
		notification = wire({ title = title, message = message, scheduled_time = os.time() }),
	}, cb)
end

--- The notifications the server has yet to send: ok, list, err.
function M.pending()
	local ok, body, err = M.request_sync("GET", "/pending?user_id=" .. user_id())
	return ok, ok and body and body.notifications or {}, err
end

return M
