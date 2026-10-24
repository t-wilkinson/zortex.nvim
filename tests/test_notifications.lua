local T = require("helpers")
local Config = require("zortex.config")
local store = require("zortex.stores.notifications")

local function with_calendar(lines, fn)
	local path = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(path)
	vim.fn.writefile(lines, path)
	require("zortex.core.document").invalidate(path)
	local ok, err = pcall(fn)
	vim.fn.writefile(original, path)
	require("zortex.core.document").invalidate(path)
	assert(ok, err)
end

T.test("calendar: a time range notifies at its start; @n(…, end) also when it ends", function()
	local cal = require("zortex.notifications.calendar")
	local day = os.date("%Y-%m-%d", os.time() + 86400)
	with_calendar({ "@@Calendar", "", day .. ":", "09:00-10:30 Dentist @n(0, 30)", "13:00-14:00 Meeting @n(10, end)" }, function()
		local got = vim.tbl_map(function(n)
			return os.date("%H:%M", n.trigger_time) .. " " .. n.tags[2] .. " " .. n.title
		end, cal.collect())
		T.eq(got, { "08:30 start Dentist", "09:00 start Dentist", "12:50 start Meeting", "14:00 end Meeting" })
	end)
end)

T.test("calendar: a timed task notifies until it is done; carried and done ones don't", function()
	local cal = require("zortex.notifications.calendar")
	local day = os.date("%Y-%m-%d", os.time() + 86400)
	with_calendar({
		"@@Calendar",
		"",
		day .. ":",
		"09:00 [ ] Write the report",
		"10:00 - 11:00 [x] Done already @n(5) @done(" .. day .. ")",
		"11:00 [>] Carried",
	}, function()
		local got = vim.tbl_map(function(n)
			return os.date("%H:%M", n.trigger_time) .. " " .. n.title
		end, cal.collect())
		T.eq(#got, 1, vim.inspect(got))
		T.ok(got[1]:match("^09:00 .*Write the report"), got[1])
		T.ok(cal.collect()[1].message:match("^09:00"), cal.collect()[1].message)
	end)
end)

T.test("calendar: all-day lines notify at all_day_time on their first day; @notify(07:30) at that time", function()
	local cal = require("zortex.notifications.calendar")
	local day = os.date("%Y-%m-%d", os.time() + 2 * 86400)
	local after = os.date("%Y-%m-%d", os.time() + 4 * 86400)
	with_calendar({
		"@@Calendar",
		"",
		day .. ":",
		"- Trip @from(" .. day .. ") @to(" .. after .. ")", -- all day: on its first day only
		"- Sam's birthday @notify", -- untimed, asked for
		"- Call the bank @notify(1d)", -- the day before
		"- [ ] Pay rent @notify(07:30)", -- a clock time
		"14:00 Dentist @notify(08:00, 10)", -- a clock time and minutes before
		"- just a note", -- untimed, nothing asked: no notification
	}, function()
		local saved = cal._cfg()
		cal.setup(vim.tbl_extend("force", saved, { all_day_time = "08:15" }))
		local got = vim.tbl_map(function(n)
			return os.date("%Y-%m-%d %H:%M", n.trigger_time) .. " " .. n.tags[2] .. " " .. n.title .. " | " .. n.message
		end, cal.collect())
		cal.setup(saved)
		local before = os.date("%Y-%m-%d", os.time() + 86400)
		T.eq(got, {
			before .. " 08:15 allday Call the bank | tomorrow",
			day .. " 07:30 at Pay rent | today",
			day .. " 08:00 at Dentist | today 14:00",
			day .. " 08:15 allday Sam's birthday | today",
			day .. " 08:15 allday Trip | today",
			day .. " 13:50 start Dentist | 14:00 (in 10 min)",
		})
	end)
end)

T.test("without a server: nothing is sent, and the commands say why", function()
	Config.server = { enabled = false }
	local msg
	local count, changed = require("zortex.notifications.calendar").sync({ on_done = function(m) msg = m end })
	T.eq({ count, changed }, { 0, false })
	T.ok(msg:match("zortex serve"), msg)
	local p = require("zortex.notifications.pomodoro")
	T.eq(p.status().error, true)
	T.ok(p.describe():match("zortex serve"), p.describe())
	T.eq(p.statusline(), "")
end)

T.test("alerts from the server: the first answer is where the list is, then each new one shows", function()
	local n = require("zortex.notifications")
	local shown = {}
	local orig = vim.notify
	vim.notify = function(m)
		shown[#shown + 1] = m
	end
	local ok, err = pcall(function()
		n.take_alerts({ seq = 4, alerts = {} })
		n.take_alerts({ seq = 6, alerts = { { kind = "calendar", title = "Dentist", message = "12:00" }, { kind = "pomodoro", title = "Break over" } } })
		n.take_alerts({ seq = 6, alerts = {} })
		n.take_alerts({ seq = 1, alerts = { { kind = "calendar", title = "Old" } } }) -- a restarted server
	end)
	vim.notify = orig
	assert(ok, err)
	T.eq(shown, { "📅 Dentist\n12:00", "🍅 Break over" })
end)

-- End to end against `zortex serve` when Go is available
local go = vim.fn.exepath("go")
if go ~= "" then
	T.test("server: calendar sync, a notification back as an alert, and the shared pomodoro clock", function()
		local bin = vim.fn.tempname()
		local build = vim.system({ go, "build", "-o", bin, "./cmd/zortex" }, { cwd = T.root .. "/app" }):wait()
		assert(build.code == 0, build.stderr)
		local port = 18000 + math.random(1000)
		local data = vim.fn.tempname()
		local proc = vim.system({ bin, "serve", "-dir", Config.notes_dir, "-data", data, "-addr", "127.0.0.1:" .. port, "-poll", "-1s", "-api-key", "k", "-send-interval", "1s" }, {})
		Config.server = { enabled = true, api_endpoint = "http://127.0.0.1:" .. port, user_id = "test", api_key = "k" }
		local server = require("zortex.notifications.server")
		local up
		for _ = 1, 50 do
			up = server.request_sync("GET", "/healthz")
			if up then
				break
			end
			vim.wait(100)
		end
		local success, err = pcall(function()
			assert(up, "server didn't start")
			-- calendar sync: sent once, not again while unchanged
			local day = os.date("%Y-%m-%d", os.time() + 86400)
			with_calendar({ "@@Calendar", "", day .. ":", "09:00 Dentist" }, function()
				store.save_calendar_manifest(nil)
				local cal = require("zortex.notifications.calendar")
				local done
				local _, changed = cal.sync({ on_done = function(m) done = m end })
				T.eq(changed, true)
				vim.wait(5000, function() return done ~= nil end)
				T.ok(done and done:match("1 added"), done)
				local okp, list = server.pending()
				T.ok(okp)
				T.eq(#list, 1)
				T.eq(list[1].title, "Dentist")
				T.eq(list[1].deduplication_key:sub(1, 4), "cal_")
				_, changed = cal.sync({ on_done = function() end })
				T.eq(changed, false)
			end)

			-- a notification now comes back as an alert
			local n = require("zortex.notifications")
			local ok0, start = server.request_sync("GET", "/api/alerts")
			T.ok(ok0)
			n.take_alerts(start)
			n.send("Stretch", "two minutes")
			local shown
			local orig = vim.notify
			vim.notify = function(m)
				shown = m
			end
			vim.wait(5000, function()
				local _, body = server.request_sync("GET", "/api/alerts?after=" .. start.seq)
				n.take_alerts(body)
				return shown ~= nil
			end, 200)
			vim.notify = orig
			T.eq(shown, "📅 Stretch\ntwo minutes")

			-- pomodoro: Neovim drives the server's clock
			local p = require("zortex.notifications.pomodoro")
			p.cleanup()
			p.start()
			local st
			vim.wait(5000, function()
				local okq, body = server.request_sync("GET", "/api/pomodoro")
				st = okq and body
				return st and st.phase == "work"
			end)
			T.eq(st.phase, "work")
			T.eq(st.running, true)
			vim.wait(3000, function() return p.status().phase == "work" end)
			T.eq(p.status().phase, "work")
			-- the website's changes are seen by Neovim
			server.request_sync("POST", "/api/pomodoro/pause", {})
			local seen
			p.refresh(function() seen = true end)
			vim.wait(3000, function() return seen end)
			T.eq(p.status().running, false)
			p.cleanup()
		end)
		proc:kill(15)
		Config.server = { enabled = false }
		assert(success, err)
	end)
end
