-- features/migrate.lua - :ZortexMigrate: bring old notes up to the current syntax
--
-- Bold headings are `**Text:**` (the colon inside). Older notes used
-- `**Text**` or `**Text**:` on a line of their own, which now read as bold
-- text and as a label. Migrate rewrites them as `**Text:**`, after showing
-- every change in the quickfix list and asking.
local M = {}

local syntax = require("zortex.core.syntax")

-- The new form of a legacy bold heading line, or nil.
function M.convert(line)
	local indent, text = line:match("^(%s*)%*%*([^*].-)%*%*:?%s*$")
	if not text or text:find("%*") or text:match(":$") then
		return nil
	end
	text = vim.trim(text)
	if text == "" then
		return nil
	end
	return indent .. "**" .. text .. ":**"
end

local function lines_of(path)
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
	end
	return vim.fn.readfile(path), nil
end

--- Every legacy bold heading in the notes: { file, lnum, text, new }.
function M.scan(files)
	files = files or require("zortex.core.notes").files({ include_archived = true })
	local out = {}
	for _, path in ipairs(files) do
		local lines = lines_of(path)
		local ast = syntax.parse(lines)
		for lnum, line in ipairs(lines) do
			local kind = ast.lines[lnum] and ast.lines[lnum].kind
			if (kind == "text" or kind == "label") and line:find("**", 1, true) then
				local new = M.convert(line)
				if new then
					out[#out + 1] = { file = path, lnum = lnum, text = line, new = new }
				end
			end
		end
	end
	return out
end

--- Rewrite the found lines (loaded buffers are changed in place and saved).
function M.apply(changes)
	local by_file = {}
	for _, c in ipairs(changes) do
		by_file[c.file] = by_file[c.file] or {}
		table.insert(by_file[c.file], c)
	end
	local n = 0
	for path, list in pairs(by_file) do
		local lines, bufnr = lines_of(path)
		for _, c in ipairs(list) do
			if lines[c.lnum] == c.text then
				lines[c.lnum] = c.new
				n = n + 1
			end
		end
		if bufnr then
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("silent write")
			end)
		else
			vim.fn.writefile(lines, path)
		end
	end
	return n
end

--- :ZortexMigrate
function M.run()
	local changes = M.scan()
	if #changes == 0 then
		vim.notify("Nothing to migrate: no old-style bold headings", vim.log.levels.INFO, { title = "Zortex" })
		return
	end
	local items = {}
	for _, c in ipairs(changes) do
		items[#items + 1] = { filename = c.file, lnum = c.lnum, text = vim.trim(c.text) .. "  →  " .. vim.trim(c.new) }
	end
	vim.fn.setqflist({}, "r", { title = "Zortex: bold headings to migrate", items = items })
	vim.cmd("copen")
	local answer = vim.fn.confirm(
		string.format("Rewrite %d old-style bold heading(s) as **Text:**? (listed in the quickfix window)", #changes),
		"&Yes\n&No",
		2
	)
	if answer ~= 1 then
		return
	end
	local n = M.apply(changes)
	vim.notify(string.format("Migrated %d bold heading(s)", n), vim.log.levels.INFO, { title = "Zortex" })
end

return M
