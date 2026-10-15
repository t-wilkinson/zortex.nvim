-- features/present.lua - A note as slides in the web app
--
-- `zortex serve` shows any note as a slide deck at /n/<note>?view=slides;
-- #L<lnum> opens the slide holding that line. The address is
-- Config.server.web_url, or api_endpoint when the web app is the same server.
local M = {}

--- The deck's URL for a note file, at the slide holding line lnum.
---@return string|nil url, string|nil err
function M.url(filepath, lnum)
	local web = require("zortex.features.web")
	local path, err = web.note_path(filepath)
	if not path then
		return nil, err
	end
	local base, berr = web.base()
	if not base then
		return nil, berr
	end
	local url = base .. path .. "?view=slides"
	if lnum and lnum > 0 then
		url = url .. "#L" .. lnum
	end
	return url
end

--- Opens the current note as slides, at the slide under the cursor.
function M.present()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" then
		return vim.notify("Not a note buffer", vim.log.levels.WARN, { title = "Zortex" })
	end
	local url, err = M.url(file, vim.api.nvim_win_get_cursor(0)[1])
	if not url then
		return vim.notify(err, vim.log.levels.WARN, { title = "Zortex" })
	end
	if vim.bo.modified then
		vim.cmd("silent! write")
	end
	local _, open_err = vim.ui.open(url)
	if open_err then
		vim.notify(open_err .. ": " .. url, vim.log.levels.WARN, { title = "Zortex" })
	end
	return url
end

return M
