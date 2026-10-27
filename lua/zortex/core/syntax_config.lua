-- core/syntax_config.lua - The note format's settings, shared with the web app
--
-- Config.syntax sets the parser's knobs (core/syntax.configure): how many
-- words a "Text:" label may have, and an optional is_label function. The
-- word count also goes to notes_dir/.z/syntax.json (synced, like every
-- device's notes), which `zortex serve` reads, so both read labels the
-- same. A function can't travel: it changes Neovim's reading only.
-- ui.calendar.group_days = false goes there too ("group_days": false), so
-- the days the web app adds to the calendar make no month headings either.
--
--   { "version": 1, "label_max_words": 5, "group_days": false }
local M = {}

M.DEFAULT_WORDS = 3

local function store()
	return require("zortex.core.state").open("syntax", {
		version = 1,
		default = function()
			return { label_max_words = M.DEFAULT_WORDS }
		end,
		-- two devices with different settings: the larger count wins, so a
		-- note's labels never stop being labels on a sync
		merge = function(mine, other)
			if (tonumber(other.label_max_words) or 0) > (tonumber(mine.label_max_words) or 0) then
				return other
			end
			return mine
		end,
	})
end

--- Apply Config.syntax to the parser and write .z/syntax.json when the
--- count (or `group_days`, ui.calendar.group_days) differs from what is
--- there (state files are written only on a change). Returns the count in use.
function M.setup(opts, group_days)
	opts = opts or {}
	local no_groups = group_days == false
	local words = math.max(1, math.floor(tonumber(opts.label_max_words) or M.DEFAULT_WORDS))
	require("zortex.core.syntax").configure({ label_max_words = words, is_label = opts.is_label })
	-- the default needs no file; otherwise the file says it (written only
	-- when its content changes, core/state)
	local State = require("zortex.core.state")
	if words ~= M.DEFAULT_WORDS or no_groups or vim.fn.filereadable(State.path("syntax")) == 1 then
		local ok, st = pcall(store)
		if ok then
			st:get().label_max_words = words
			if no_groups then
				st:get().group_days = false
			else
				st:get().group_days = nil
			end
			pcall(st.save, st)
		end
	end
	return words
end

return M
