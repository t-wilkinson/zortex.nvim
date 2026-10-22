-- features/rename.lua - The rename half of :ZortexMove (features/move): a
-- heading, bold heading or label gets a new title and every link through
-- it is rewritten.
--
-- The links come from the link index (link_index.references over the whole
-- section, so [P/#1.4 - zortex/-Improve website] counts too). In each, the
-- component that finds the section is the one rewritten, and only when it
-- stops matching: "#1.4" still finds "1.4 - zortex.nvim", so it stays; a
-- renumbering ("1.4" -> "2.3") rewrites it to the new text.
local M = {}

local workspace = require("zortex.core.workspace")
local link_mod = require("zortex.core.link")

local SIGIL = { heading = "#", label = ":", bold_heading = "*" }

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

local function same_file(a, b)
	return vim.fn.fnamemodify(a, ":p") == vim.fn.fnamemodify(b, ":p")
end

--- The section starting on `lnum` that can be renamed, or nil and why.
function M.section(doc, lnum)
	local node = doc and doc:node_starting_at(lnum)
	if not node or not SIGIL[node.type] then
		return nil, "not on a heading, bold heading or label"
	end
	return node
end

--- `line` (the section's own line) with its title `old` replaced by `new`;
--- the markers around it and its @attributes stay.
function M.retitle(line, old, new)
	local s, e = line:find(old, 1, true)
	if not s then
		return nil
	end
	return line:sub(1, s - 1) .. new .. line:sub(e + 1)
end

-- Index of the component of `def` that finds the section (file, lnum), or nil
local function component_at(def, from_file, from_lnum, file, lnum)
	local comps, scope = link_mod.split(def)
	local opts = { doc = workspace.document(from_file), lnum = from_lnum }
	for i = 1, #comps do
		local prefix = (scope == "local" and "/" or "") .. table.concat(comps, "/", 1, i)
		local ok, results = pcall(link_mod.resolve, "[" .. prefix .. "]", opts)
		local r = ok and results and results[1]
		if r and r.lnum == lnum and same_file(r.file, file) then
			return i, comps, scope
		end
	end
end

--- The edits renaming the section at `lnum` of `file` to `new`:
--- { title = { file, lnum, line }, links = { { file, lnum, line } ... }, count }
--- Nothing is written.
function M.plan(file, lnum, new)
	local doc = workspace.document(file)
	local node, err = M.section(doc, lnum)
	if not node then
		return nil, err
	end
	new = vim.trim(new or "")
	if new == "" then
		return nil, "empty title"
	end
	local title = M.retitle(doc.lines[lnum], node.text, new)
	if not title then
		return nil, "can't find the title in its line"
	end
	local text = link_mod.component_text(new)
	local sigil = SIGIL[node.type]

	-- Old link text -> new, line by line (several links can share a line)
	local by_line, order = {}, {}
	for _, ref in ipairs(require("zortex.core.link_index").references(file, node.start_line, node.end_line)) do
		local i, comps, scope = component_at(ref.definition, ref.file, ref.lnum, file, lnum)
		if i then
			local old = comps[i]
			local kept = old:sub(2):gsub("^ ", ""):lower()
			-- a component of another kind (a %query landing on the line) is left
			-- alone; one that is still a prefix of the new title still finds it
			if old:sub(1, 1) == sigil and (kept == "" or text:lower():sub(1, #kept) ~= kept) then
				comps[i] = sigil .. text
				local def = (scope == "local" and "/" or "") .. table.concat(comps, "/")
				local key = ref.file .. ":" .. ref.lnum
				if not by_line[key] then
					by_line[key] = { file = ref.file, lnum = ref.lnum, subs = {} }
					order[#order + 1] = key
				end
				table.insert(by_line[key].subs, { col = ref.def_col or ref.col, old = ref.definition, new = def })
			end
		end
	end

	local links, count = {}, 0
	for _, key in ipairs(order) do
		local l = by_line[key]
		local line = workspace.get_lines(l.file)[l.lnum]
		if same_file(l.file, file) and l.lnum == lnum then
			line = title
		end
		table.sort(l.subs, function(a, b)
			return a.col > b.col
		end)
		for _, sub in ipairs(l.subs) do
			-- the definition starts after "[" (or "!["), or after "](" in
			-- [text](definition)
			local at = line:find(sub.old, sub.col, true)
			if at then
				line = line:sub(1, at - 1) .. sub.new .. line:sub(at + #sub.old)
				count = count + 1
			end
		end
		links[#links + 1] = { file = l.file, lnum = l.lnum, line = line }
	end
	return { title = { file = file, lnum = lnum, line = title }, links = links, count = count, node = node, new = new }
end

-- The notes a plan changes, the title's first
local function plan_files(plan)
	local files, seen = {}, {}
	for _, e in ipairs({ plan.title, unpack(plan.links) }) do
		local p = vim.fn.fnamemodify(e.file, ":p")
		if not seen[p] then
			seen[p] = true
			files[#files + 1] = p
		end
	end
	return files
end

--- Apply a plan: the title, then the links, as one batch (core/workspace):
--- notes that aren't open are loaded, edited and saved, and :ZortexUndo
--- takes the whole rename back. Returns how many notes changed, or nil and
--- an error (a note changed since the plan was made: nothing more written).
function M.apply(plan)
	local files = plan_files(plan)
	local ok, err = workspace.batch("rename to " .. vim.trim(plan.new or ""), files, function()
		local ok1, err1 = workspace.set_line(plan.title.file, plan.title.lnum, plan.title.line)
		if not ok1 then
			return false, err1
		end
		for _, e in ipairs(plan.links) do
			local ok2, err2 = workspace.set_line(e.file, e.lnum, e.line)
			if not ok2 then
				return false, err2
			end
		end
		return true
	end)
	if not ok then
		return nil, err
	end
	return #files
end

return M
