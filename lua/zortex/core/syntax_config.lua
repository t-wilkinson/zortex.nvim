-- core/syntax_config.lua - The note format's settings, shared with the web app
--
-- Config.syntax sets the parser's knobs (core/syntax.configure): how many
-- words a "Text:" label may have, and an optional is_label function. The
-- word count also goes to notes_dir/.z/syntax.json (synced, like every
-- device's notes), which `zortex serve` reads, so both read labels the
-- same. A function can't travel: it changes Neovim's reading only.
--
--   { "version": 1, "label_max_words": 5 }
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
--- count differs from what is there (state files are written only on a
--- change). Returns the count in use.
function M.setup(opts)
	opts = opts or {}
	local words = math.max(1, math.floor(tonumber(opts.label_max_words) or M.DEFAULT_WORDS))
	require("zortex.core.syntax").configure({ label_max_words = words, is_label = opts.is_label })
	-- the default needs no file; otherwise the file says it (written only
	-- when its content changes, core/state)
	local State = require("zortex.core.state")
	if words ~= M.DEFAULT_WORDS or vim.fn.filereadable(State.path("syntax")) == 1 then
		local ok, st = pcall(store)
		if ok then
			st:get().label_max_words = words
			pcall(st.save, st)
		end
	end
	return words
end

return M
