local T = require("helpers")
local Config = require("zortex.config")
local manager = require("zortex.notifications.manager")
local store = require("zortex.stores.notifications")

manager.setup({ providers = {}, channels = {} })

-- capture what would be sent
local sent = {}
local real_send = manager.send_notification
manager.send_notification = function(title, message, opts)
	sent[#sent + 1] = { title = title, message = message, opts = opts }
end

T.test("pomodoro (local clock): cycle, events, ntfy-only routing", function()
	Config.server = { enabled = false }
	store.save_pomodoro(nil)
	local p = require("zortex.notifications.types.pomodoro")
	p.setup({ work_duration = 25, short_break = 5, long_break = 15, long_break_after = 2, auto_start_break = true, auto_start_work = true, sounds = { work_start = false, break_start = false, restart = false } }, {
		ntfy = { enabled = true, topic = "t" },
	})
	sent = {}
	local st = p.start()
	T.eq(st.phase, "work")
	T.eq(sent[1].opts.tags[3], "pomodoro-work-start")
	T.eq(sent[1].opts.channels, { "ntfy" }) -- ntfy enabled: nothing else
	T.ok(p.status().remaining_formatted:match("^2[45]:%d%d$"), p.status().remaining_formatted)

	-- skip is an explicit phase end: work -> short break
	sent = {}
	p.skip()
	T.eq(p.status().phase, "short_break")
	T.eq(sent[1].opts.tags[3], "pomodoro-break-start")
	p.skip() -- -> work 2
	p.skip() -- -> long break (2 sessions done)
	T.eq(p.status().phase, "long_break")
	sent = {}
	p.skip() -- -> new cycle
	T.eq(sent[1].opts.tags[3], "pomodoro-restart")
	T.eq(p.status().session, 1)
	T.eq(p.status().today, 2)

	p.toggle() -- pause
	T.eq(p.status().running, false)
	T.ok(p.describe():match("paused"), p.describe())
	p.stop()
	T.eq(p.status().phase, "idle")
	T.ok(p.update_settings({ work = 50 }))
	T.eq(p.status().settings.work, 50)
	p.cleanup()
end)

T.test("calendar sync: unchanged calendars are not re-sent", function()
	Config.server = { enabled = false }
	local cal = require("zortex.notifications.types.calendar")
	cal.setup = cal.setup -- (no initial sync in tests)
	local path = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(path)
	local day = os.date("%Y-%m-%d", os.time() + 86400)
	vim.fn.writefile({ "@@Calendar", "", day .. ":", "09:00 Dentist", "14:00 Meeting @notify(10)" }, path)
	require("zortex.core.document").invalidate(path)

	store.save_calendar_manifest(nil)
	local msgs = {}
	local function sync(opts)
		opts = opts or {}
		opts.on_done = function(m)
			msgs[#msgs + 1] = m
		end
		return require("zortex.notifications.types.calendar").sync(opts)
	end
	local list = cal.collect()
	T.eq(#list, 2)
	T.ok(list[2].message:match("^14:00 %(in 10 min%)$"), list[2].message)
	local count, changed = sync()
	T.eq({ count, changed }, { 2, true })
	count, changed = sync()
	T.eq({ count, changed }, { 2, false })
	T.ok(msgs[#msgs]:match("unchanged"), msgs[#msgs])
	T.eq(#manager.list_scheduled({ type = "calendar" }), 2)

	-- move an entry: changed, and the local schedule follows
	vim.fn.writefile({ "@@Calendar", "", day .. ":", "10:00 Dentist", "14:00 Meeting @notify(10)" }, path)
	require("zortex.core.document").invalidate(path)
	count, changed = sync()
	T.eq(changed, true)
	local scheduled = manager.list_scheduled({ type = "calendar" })
	T.eq(#scheduled, 2)
	T.eq(os.date("%H:%M", scheduled[1].trigger_time), "10:00")
	-- force resends
	_, changed = sync({ force = true })
	T.eq(changed, true)

	for _, n in ipairs(manager.list_scheduled({ type = "calendar" })) do
		manager.cancel_notification(n.id)
	end
	vim.fn.writefile(original, path)
	require("zortex.core.document").invalidate(path)
end)

T.test("calendar: a time range notifies at its start; @n(…, end) also when it ends", function()
	local cal = require("zortex.notifications.types.calendar")
	local path = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(path)
	local day = os.date("%Y-%m-%d", os.time() + 86400)
	vim.fn.writefile({
		"@@Calendar",
		"",
		day .. ":",
		"09:00-10:30 Dentist @n(0, 30)",
		"13:00-14:00 Meeting @n(10, end)",
	}, path)
	require("zortex.core.document").invalidate(path)
	local got = vim.tbl_map(function(n)
		return os.date("%H:%M", n.trigger_time) .. " " .. n.tags[2] .. " " .. n.title
	end, cal.collect())
	vim.fn.writefile(original, path)
	require("zortex.core.document").invalidate(path)
	T.eq(got, {
		"08:30 start Dentist",
		"09:00 start Dentist",
		"12:50 start Meeting",
		"14:00 end Meeting",
	})
end)

-- End to end against `zortex serve` when Go is available
local go = vim.fn.exepath("go")
if go ~= "" then
	T.test("server: calendar sync and the shared pomodoro clock", function()
		local bin = vim.fn.tempname()
		local build = vim.system({ go, "build", "-o", bin, "./cmd/zortex" }, { cwd = T.root .. "/app" }):wait()
		assert(build.code == 0, build.stderr)
		local port = 18000 + math.random(1000)
		local data = vim.fn.tempname()
		local proc = vim.system({ bin, "serve", "-dir", Config.notes_dir, "-data", data, "-addr", "127.0.0.1:" .. port, "-poll", "-1s", "-api-key", "k" }, {})
		Config.server = { enabled = true, api_endpoint = "http://127.0.0.1:" .. port, user_id = "test", api_key = "k" }
		local server = require("zortex.notifications.server")
		local ok
		for _ = 1, 50 do
			ok = server.request_sync("GET", "/healthz")
			if ok then
				break
			end
			vim.wait(100)
		end
		local success, err = pcall(function()
			assert(ok, "server didn't start")
			-- calendar sync
			local path = require("zortex.utils.filesystem").get_calendar_file()
			local original = vim.fn.readfile(path)
			local day = os.date("%Y-%m-%d", os.time() + 86400)
			vim.fn.writefile({ "@@Calendar", "", day .. ":", "09:00 Dentist" }, path)
			require("zortex.core.document").invalidate(path)
			store.save_calendar_manifest(nil)
			local done
			local _, changed = require("zortex.notifications.types.calendar").sync({ on_done = function(m) done = m end })
			T.eq(changed, true)
			vim.wait(5000, function() return done ~= nil end)
			T.ok(done and done:match("1 added"), done)
			local okp, pending = server.request_sync("GET", "/pending?user_id=test")
			T.ok(okp)
			T.eq(pending.count, 1)
			T.eq(pending.notifications[1].title, "Dentist")
			T.eq(pending.notifications[1].deduplication_key:sub(1, 4), "cal_")
			_, changed = require("zortex.notifications.types.calendar").sync({ on_done = function() end })
			T.eq(changed, false) -- nothing sent the second time
			vim.fn.writefile(original, path)
			require("zortex.core.document").invalidate(path)

			-- pomodoro: Neovim drives the server's clock
			local p = require("zortex.notifications.types.pomodoro")
			p.cleanup()
			p.setup({ work_duration = 30, short_break = 5, long_break = 15, long_break_after = 4 }, {})
			T.ok(p.remote())
			store.save_pomodoro_pushed(nil)
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
			-- the website's view changes are seen by Neovim
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

manager.send_notification = real_send

T.test("pomodoro sound_command: a program, a string with arguments, or a list", function()
	local argv = require("zortex.notifications.types.pomodoro").sound_argv
	T.eq(argv("paplay", "/s/a.oga"), { "paplay", "/s/a.oga" })
	T.eq(argv("pw-play --volume 0.5", "/s/a.oga"), { "pw-play", "--volume", "0.5", "/s/a.oga" })
	T.eq(argv({ "mpv", "--no-video", "%s", "--volume=60" }, "/s/a b.oga"), { "mpv", "--no-video", "/s/a b.oga", "--volume=60" })
	T.eq(argv({ "play", "--file=%s" }, "/s/a%.oga"), { "play", "--file=/s/a%.oga" })
	T.eq(argv(nil, "/s/a.oga")[2], "/s/a.oga")
end)
