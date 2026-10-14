-- features/present.lua - A note as slides in the web app
--
-- `zortex serve` shows any note as a slide deck at /n/<note>?view=slides;
-- #L<lnum> opens the slide holding that line. The address is
-- Config.server.web_url, or api_endpoint when the web app is the same server.
local M = {}

local Config = require("zortex.config")

local function escape(segment)
	return (segment:gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

--- The deck's URL for a note file, at the slide holding line lnum.
---@return string|nil url, string|nil err
function M.url(filepath, lnum)
	local root = vim.fs.normalize(vim.fn.fnamemodify(Config.notes_dir, ":p")):gsub("/+$", "")
	local path = vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p"))
	if path:sub(1, #root + 1) ~= root .. "/" then
		return nil, "Not a note in notes_dir"
	end
	local parts = vim.split(path:sub(#root + 2), "/", { plain = true })
	for i, p in ipairs(parts) do
		parts[i] = escape(p)
	end
	local server = Config.server or {}
	local web = server.web_url or server.api_endpoint
	if type(web) ~= "string" or web == "" then
		return nil, "Set server.web_url to the web app's address"
	end
	local url = web:gsub("/+$", "") .. "/n/" .. table.concat(parts, "/") .. "?view=slides"
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
