-- features/rename.lua - :ZortexRename (<leader>zR): rename the heading,
-- bold heading or label under the cursor and rewrite every link through it.
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
				table.insert(by_line[key].subs, { col = ref.col, old = ref.definition, new = def })
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
			-- the definition starts after "[" (or "![")
			local at = line:find(sub.old, sub.col, true)
			if at then
				line = line:sub(1, at - 1) .. sub.new .. line:sub(at + #sub.old)
				count = count + 1
			end
		end
		links[#links + 1] = { file = l.file, lnum = l.lnum, line = line }
	end
	return { title = { file = file, lnum = lnum, line = title }, links = links, count = count, node = node }
end

--- Apply a plan: the title, then the links (buffers if loaded, else files).
function M.apply(plan)
	workspace.set_line(plan.title.file, plan.title.lnum, plan.title.line)
	local files = { [vim.fn.fnamemodify(plan.title.file, ":p")] = true }
	for _, e in ipairs(plan.links) do
		workspace.set_line(e.file, e.lnum, e.line)
		files[vim.fn.fnamemodify(e.file, ":p")] = true
	end
	return vim.tbl_count(files)
end

--- :ZortexRename [new title]: rename the section under the cursor.
function M.rename_current(args)
	local doc = require("zortex.core.document").from_buffer(0)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local node = doc and (doc:node_starting_at(lnum) or doc:node_at(lnum))
	if not node or not SIGIL[node.type] then
		return notify("Put the cursor on a heading, bold heading or label", vim.log.levels.WARN)
	end
	local file = vim.api.nvim_buf_get_name(0)
	local function run(new)
		if not new or vim.trim(new) == "" or vim.trim(new) == node.text then
			return
		end
		local plan, err = M.plan(file, node.start_line, new)
		if not plan then
			return notify("Rename: " .. err, vim.log.levels.ERROR)
		end
		local files = M.apply(plan)
		notify(
			string.format(
				"Renamed to %s; %d link%s rewritten in %d note%s",
				vim.trim(new),
				plan.count,
				plan.count == 1 and "" or "s",
				files,
				files == 1 and "" or "s"
			)
		)
	end
	local given = args and args.args
	if given and given ~= "" then
		return run(given)
	end
	vim.ui.input({ prompt = "Rename to: ", default = node.text }, run)
end

return M
