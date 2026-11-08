-- core/syntax_config.lua - The note format's settings, shared with the web app
--
-- Config.syntax sets the parser's knobs (core/syntax.configure): which
-- "Key:" lines (one colon) read as labels, by word count
-- (label_max_words) and a Lua pattern (label_pattern). Both go to
-- notes_dir/.z/syntax.json (synced, like every device's notes), which
-- `zortex serve` reads, so both read labels the same.
-- ui.calendar.group_days = false goes there too ("group_days": false), so
-- the days the web app adds to the calendar make no month headings either,
-- and Config.documents when it isn't the default (core/documents), so the
-- web app reads the same Markdown and HTML folders.
--
--   { "version": 1, "label_max_words": 5, "label_pattern": "^%u%u+$",
--     "group_days": false, "documents": ["docs"] }
local M = {}

M.DEFAULT_WORDS = 3

local function store()
	return require("zortex.core.state").open("syntax", {
		version = 1,
		default = function()
			return { label_max_words = M.DEFAULT_WORDS }
		end,
		-- two devices with different settings: the larger count wins (with
		-- its pattern), so the file settles instead of flipping on each sync
		merge = function(mine, other)
			if (tonumber(other.label_max_words) or 0) > (tonumber(mine.label_max_words) or 0) then
				return other
			end
			return mine
		end,
	})
end

--- Apply Config.syntax to the parser and write .z/syntax.json when the
--- rule (or `group_days`, ui.calendar.group_days) differs from what is
--- there (state files are written only on a change). Returns the word
--- count in use.
function M.setup(opts, group_days, documents)
	opts = opts or {}
	local no_groups = group_days == false
	local folders
	if documents ~= nil then
		local D = require("zortex.core.documents")
		folders = D.folders()
		if vim.deep_equal(folders, D.DEFAULT) then
			folders = nil -- the default needs no saying
		end
	end
	local words = math.max(0, math.floor(tonumber(opts.label_max_words) or M.DEFAULT_WORDS))
	local pattern = type(opts.label_pattern) == "string" and opts.label_pattern ~= "" and opts.label_pattern or nil
	local ok, err = require("zortex.core.syntax").configure({ label_max_words = words, label_pattern = pattern })
	if not ok then
		pattern = nil
		vim.schedule(function()
			vim.notify("zortex: syntax.label_pattern is not a Lua pattern (" .. tostring(err) .. ")", vim.log.levels.WARN)
		end)
	end
	if opts.is_label ~= nil then
		vim.schedule(function()
			vim.notify(
				"zortex: syntax.is_label is gone; use syntax.label_pattern (a Lua pattern) and label_max_words",
				vim.log.levels.WARN
			)
		end)
	end
	-- the default needs no file; otherwise the file says it (written only
	-- when its content changes, core/state)
	local State = require("zortex.core.state")
	if words ~= M.DEFAULT_WORDS or pattern or no_groups or folders or vim.fn.filereadable(State.path("syntax")) == 1 then
		local opened, st = pcall(store)
		if opened then
			st:get().label_max_words = words
			st:get().label_pattern = pattern
			if no_groups then
				st:get().group_days = false
			else
				st:get().group_days = nil
			end
			st:get().documents = folders
			pcall(st.save, st)
		end
	end
	return words
end

return M
