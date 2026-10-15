-- ui/picker/search.lua - The structural search picker (services/search does
-- the matching and ranking; this lists its results, live, in its order).
--
--   <CR>   open (split / vsplit / tab: the picker's own keys)
--   <C-o>  new note named after the query
--   <M-t>  cycle section / article / text search
local search = require("zortex.services.search")
local Picker = require("zortex.ui.picker")
local fs = require("zortex.utils.filesystem")
local Config = require("zortex.config")

local M = {}

local function cfg()
	return search.config or search.setup()
end

-- A section node's highlight group (as in the note)
local function node_hl(node)
	local ntype = node.type and tostring(node.type):lower() or ""
	if ntype == "article" then
		return "ZortexArticle"
	elseif ntype == "heading" then
		return "ZortexHeading" .. math.min(tonumber(node.level) or 1, 3)
	elseif ntype == "bold_heading" then
		return "ZortexBoldHeading"
	elseif ntype == "label" then
		return "ZortexLabel"
	end
	return nil
end

-- A text line's highlight group (tasks, labels, bullets, numbered lists)
local function line_hl(line)
	if line:match("^%s*%-%s*%[x%]") then
		return "ZortexTaskDone"
	elseif line:match("^%s*%-%s*%[.?%]") then
		return "ZortexTaskText"
	elseif line:match("^%s*%-%s*%w[^:]*:%s") and not line:find("%.%s.-:") then
		return "ZortexLabelListText"
	elseif line:match("^%s*%-%s*%w[^:]*:$") and not line:find("%.%s.-:") then
		return "ZortexLabelList"
	elseif line:match("^%s*%-") then
		local indent = #(line:match("^(%s*)") or "")
		return "ZortexBullet" .. math.min(math.floor(indent / 2) + 1, 4)
	elseif line:match("^%s*%d+%.") then
		return "ZortexNumberList"
	end
	return nil
end

-- "Article › Heading › Label", or "Article › the line"
function M.format(r)
	local out = {}
	if r.result_type == "section" then
		for _, node in ipairs(r.node:get_full_path()) do
			if node.type ~= "root" then
				if #out > 0 then
					out[#out + 1] = { " › ", "Comment" }
				end
				out[#out + 1] = { node.text or "Untitled", node_hl(node) }
			end
		end
		if r.archived then
			out[#out + 1] = { "  (archive)", "Comment" }
		end
		return out
	end
	if r.article_name then
		out[#out + 1] = { r.article_name, "ZortexArticle" }
		out[#out + 1] = { " › ", "Comment" }
	end
	out[#out + 1] = { vim.trim(r.line), line_hl(r.line) }
	if r.file_match then
		out[#out + 1] = { "  (file " .. r.file_match .. ")", "Comment" }
	end
	return out
end

function M.location(r)
	if r.result_type == "section" then
		return { file = r.filepath, lnum = r.node.start_line, col = 1, text = r.breadcrumb }
	end
	return { file = r.filepath, lnum = r.lnum, col = r.col or 1, text = vim.trim(r.line) }
end

function M.preview(r)
	local lines = fs.read_lines(r.filepath)
	if not lines then
		return nil
	end
	local p = { lines = lines, zortex = true, title = vim.fn.fnamemodify(r.filepath, ":t") }
	if r.result_type == "section" then
		p.lnum, p.range = r.node.start_line, { r.node.start_line, r.node.end_line }
	else
		p.lnum = r.lnum
	end
	return p
end

-- A new note "YYYY-MM-DD.NNN.zortex" named after the query
function M.new_note(name)
	local date = os.date("%Y-%m-%d")
	math.randomseed(os.time() + os.clock() * 1000)
	for _ = 1, 1000 do
		local filepath = fs.get_file_path(string.format("%s.%03d%s", date, math.random(0, 999), Config.extension))
		if filepath and not fs.file_exists(filepath) then
			vim.cmd("edit " .. vim.fn.fnameescape(filepath))
			local first = "@@" .. (name or "")
			vim.api.nvim_buf_set_lines(0, 0, 0, false, { first })
			vim.api.nvim_win_set_cursor(0, { 1, #first })
			vim.cmd("startinsert!")
			return filepath
		end
	end
	vim.notify("Failed to create unique filename", vim.log.levels.ERROR)
end

local function title(mode)
	if mode == "text" then
		return "Zortex Text Search"
	end
	return "Zortex Structural Search (" .. mode .. ")"
end

-- section -> article -> text -> section
local function next_mode(mode)
	for i, m in ipairs(search.MODES) do
		if m == mode then
			return search.MODES[i % #search.MODES + 1]
		end
	end
	return search.MODES[1]
end

--- The picker spec (ui/picker); opts.mode: "section" | "article" | "text".
function M.spec(opts)
	opts = opts or {}
	local mode = opts.mode or cfg().default_mode or "section"
	-- Every note is read and parsed once, here; typing only filters the index
	local index = search.build_index(search.files())
	local history = require("zortex.services.search_history")
	return {
		title = function()
			return title(mode)
		end,
		query = function(prompt)
			return search.query_index(index, prompt, { mode = mode })
		end,
		format = M.format,
		location = M.location,
		preview = M.preview,
		on_open = function(r)
			history.record(r)
		end,
		prompt = opts.prompt,
		keys = {
			["<C-o>"] = {
				desc = "New note named after the query",
				close = true,
				fn = function(_, ctx)
					M.new_note(ctx.prompt)
				end,
			},
			["<M-t>"] = {
				desc = "Cycle section / article / text search",
				refresh = true,
				fn = function()
					mode = next_mode(mode)
				end,
			},
		},
	}
end

function M.open(opts)
	return Picker.pick(M.spec(opts))
end

return M
