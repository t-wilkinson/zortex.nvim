-- ui/picker/search.lua - The structural search picker (services/search does
-- the matching and ranking; this lists its results, live, in its order).
--
--   <CR>   open (split / vsplit / tab: the picker's own keys)
--   <C-o>  new note named after the query          (ui.search.keys.new_note)
--   <M-t>  cycle section / article / text search   (ui.search.keys.cycle_mode)
--   <M-n>  narrow to the section under the cursor  (ui.search.keys.narrow):
--          only what is inside it, every line, no cap; the prompt typed so
--          far stays and what you type after it searches inside
--   <M-p>  back out of the last narrowing          (ui.search.keys.widen)
-- The title shows the keys.
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

-- the keys go after it (ui/picker title, from zortex.keys)
local function title(mode, scope)
	local t = mode == "text" and "Zortex Text Search" or ("Zortex Structural Search (" .. mode .. ")")
	if scope then
		t = t .. " in " .. scope.breadcrumb
	end
	return t
end

-- The prompt inside a narrowing: what was typed after the words that found
-- the section (the whole prompt when those were changed)
local function inside(prompt, prefix)
	prompt = prompt or ""
	if prefix ~= "" and prompt:sub(1, #prefix) == prefix then
		return prompt:sub(#prefix + 1)
	end
	return prompt
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

--- The note being edited, when it is one (opts.here: a path, or false for
--- none): its own sections and lines come first (ui.search.here).
local function here_of(opts)
	if opts.here ~= nil then
		return opts.here or nil
	end
	if cfg().here == false then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(0)
	local ext = require("zortex.config").extension or ".zortex"
	if name ~= "" and name:sub(-#ext) == ext then
		return name
	end
	return nil
end

--- The picker spec (ui/picker); opts.mode: "section" | "article" | "text";
--- opts.all_sections: sections at any depth whatever the number of words;
--- opts.new_note = false: no key for a new note; opts.here: the note whose
--- own results come first (default: the one being edited; false: none).
function M.spec(opts)
	opts = opts or {}
	local mode = opts.mode or cfg().default_mode or "section"
	local here = here_of(opts)
	-- Every note is read and parsed once, here; typing only filters the index
	local index = search.build_index(search.files())
	local history = require("zortex.services.search_history")
	-- narrowings, innermost last: { scope, prefix (the prompt then) }
	local scopes = {}
	local function current()
		return scopes[#scopes]
	end
	return {
		title = function()
			return title(mode, current() and current().scope)
		end,
		query = function(prompt)
			local cur = current()
			if cur then
				prompt = inside(prompt, cur.prefix)
			end
			return search.query_index(index, prompt, { mode = mode, all_sections = opts.all_sections, scope = cur and cur.scope, here = here })
		end,
		format = M.format,
		location = M.location,
		preview = M.preview,
		on_open = function(r)
			history.record(r)
		end,
		prompt = opts.prompt,
		-- the keys: zortex.keys ("search"; ui.search.keys sets them)
		keys = require("zortex.keys").picker_keys("search", {
			new_note = opts.new_note ~= false and {
				close = true,
				fn = function(_, ctx)
					M.new_note(ctx.prompt)
				end,
			} or nil,
			cycle_mode = {
				refresh = true,
				fn = function()
					mode = next_mode(mode)
				end,
			},
			narrow = {
				refresh = true,
				fn = function(item, ctx)
					local scope = search.scope_of(item)
					if scope then
						scopes[#scopes + 1] = { scope = scope, prefix = ctx.prompt or "" }
					end
				end,
			},
			widen = {
				refresh = true,
				fn = function()
					scopes[#scopes] = nil
				end,
			},
		}),
	}
end

function M.open(opts)
	return Picker.pick(M.spec(opts))
end

return M
