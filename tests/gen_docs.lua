-- tests/gen_docs.lua - Regenerate the command/key table in README.md
--
--   nvim --headless -u NONE -l tests/gen_docs.lua
--
-- The table between <!-- actions:start --> and <!-- actions:end --> is built
-- from zortex.actions; test_zr_actions fails when it is out of date.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local M = {}
M.readme = root .. "/README.md"
M.START, M.STOP = "<!-- actions:start -->", "<!-- actions:end -->"

--- Markdown for every action, grouped, with the default prefixes.
function M.actions_markdown()
	local actions = require("zortex.actions")
	local out, group = {}, nil
	for _, a in ipairs(actions.list) do
		if a.group ~= group then
			group = a.group
			if #out > 0 then
				out[#out + 1] = ""
			end
			out[#out + 1] = "**" .. group .. "**"
			out[#out + 1] = ""
			out[#out + 1] = "| Command | Keys | Action id | Does |"
			out[#out + 1] = "|---|---|---|---|"
		end
		local keys = type(a.key) == "table" and a.key or { a.key }
		local key_cells = vim.tbl_map(function(k)
			return "`<leader>z" .. k .. "`"
		end, keys)
		out[#out + 1] = string.format(
			"| %s | %s | `%s` | %s |",
			a.command and ("`:Zortex" .. a.command .. (a.nargs and a.nargs ~= 0 and " …" or "") .. "`") or "",
			table.concat(key_cells, " "),
			a.id,
			(a.desc:gsub("|", "\\|"))
		)
	end
	return out
end

--- The README with the generated block replaced.
function M.render_readme(lines)
	local out, skipping = {}, false
	for _, line in ipairs(lines) do
		if line == M.START then
			out[#out + 1] = line
			vim.list_extend(out, M.actions_markdown())
			skipping = true
		elseif line == M.STOP then
			skipping = false
			out[#out + 1] = line
		elseif not skipping then
			out[#out + 1] = line
		end
	end
	return out
end

if not package.loaded["helpers"] then
	vim.fn.writefile(M.render_readme(vim.fn.readfile(M.readme)), M.readme)
	print("updated " .. M.readme)
	os.exit(0)
end

return M
