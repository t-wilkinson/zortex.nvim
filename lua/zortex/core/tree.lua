-- core/tree.lua - Persistent Structural Tree Module
local M = {}
local Section = require("zortex.core.section").Section
local parser = require("zortex.utils.parser")
local constants = require("zortex.constants")
local fs = require("zortex.utils.filesystem")

local cache_file = vim.fn.stdpath("cache") .. "/zortex/trees.json"
local cache_data = nil

-- In-memory cache of *live* (rehydrated) trees, keyed by filepath.
-- This avoids rebuilding the whole Section object graph from JSON on every
-- get_tree() call. Entries are validated against the file mtime.
--
-- CAVEAT: callers receive a shared, mutable tree. Read-only consumers (e.g.
-- search) are safe. Anything that mutates nodes in place (Section:update_bounds,
-- etc.) must either operate on a copy or call M.invalidate() afterwards.
local live_cache = {}

-- Load cache from disk
local function load_cache()
	if cache_data then
		return cache_data
	end
	local f = io.open(cache_file, "r")
	if f then
		local content = f:read("*a")
		f:close()
		local ok, parsed = pcall(vim.fn.json_decode, content)
		if ok and type(parsed) == "table" then
			cache_data = parsed
		else
			cache_data = {}
		end
	else
		cache_data = {}
	end
	return cache_data
end

-- Save cache to disk
local function save_cache()
	if not cache_data then
		return
	end
	vim.fn.mkdir(vim.fn.fnamemodify(cache_file, ":h"), "p")
	local f = io.open(cache_file, "w")
	if f then
		f:write(vim.fn.json_encode(cache_data))
		f:close()
	end
end

-- Dehydrate section to strip cyclic relationships and metatables for JSON
local function dehydrate(section)
	local data = {
		type = section.type,
		text = section.text,
		start_line = section.start_line,
		end_line = section.end_line,
		level = section.level,
		children = {},
	}
	for _, child in ipairs(section.children) do
		table.insert(data.children, dehydrate(child))
	end
	return data
end

-- Rehydrate section to restore cyclical object graphs (`.parent`) and metatables
local function rehydrate(data, parent)
	local section = Section:new({
		type = data.type,
		text = data.text,
		start_line = data.start_line,
		end_line = data.end_line,
		level = data.level,
	})
	section.parent = parent
	for _, child_data in ipairs(data.children) do
		table.insert(section.children, rehydrate(child_data, section))
	end
	return section
end

-- Assigns strict numerical levels to Zortex hierarchy
local function calculate_level(line, is_code)
	local section_type = parser.detect_section_type(line, is_code)
	if section_type == constants.SECTION_TYPE.ARTICLE then
		return 0, section_type
	elseif section_type == constants.SECTION_TYPE.HEADING then
		local level = parser.get_heading_level(line)
		return level, section_type -- Levels 1-6
	elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
		return 7, section_type
	elseif section_type == constants.SECTION_TYPE.LABEL then
		local indent = #line:match("^%s*")
		return 8 + indent, section_type -- Base level 8 + indentation rules
	end
	return nil, section_type
end

-- Parse lines into a structural tree
local function parse_tree(filepath)
	local lines = fs.read_lines(filepath)
	if not lines then
		return nil
	end

	local root = Section:new({
		type = "root",
		text = "Root",
		start_line = 1,
		end_line = #lines,
	})
	root.level = -1

	local stack = { root }
	local code_tracker = parser.CodeBlockTracker:new()
	local in_article_block = true

	for lnum, line in ipairs(lines) do
		local in_code = code_tracker:update(line)
		local level, section_type = calculate_level(line, in_code)

		-- Article continuity check
		if level then
			if section_type == constants.SECTION_TYPE.ARTICLE then
				if not in_article_block then
					level = nil
				end
			else
				in_article_block = false
			end
		else
			if vim.trim(line) ~= "" then
				in_article_block = false
			end
		end

		if level then
			local text = ""
			if section_type == constants.SECTION_TYPE.ARTICLE then
				text = parser.extract_article_name(line) or "Article"
			elseif section_type == constants.SECTION_TYPE.HEADING then
				local h = parser.parse_heading(line)
				text = h and h.text or line:gsub("^#+%s*", "")
			elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
				local bh = parser.parse_bold_heading(line)
				text = bh and bh.text or line:match("%*%*(.-)%*%*") or line
			elseif section_type == constants.SECTION_TYPE.LABEL then
				local lbl = parser.parse_label(line)
				text = lbl and lbl.text or line:match("^%s*(.-):") or line
			end

			local section = Section:new({
				type = section_type,
				text = vim.trim(text),
				start_line = lnum,
				end_line = lnum,
				level = level,
			})

			-- Enforce structural hierarchy popping
			while #stack > 1 and stack[#stack].level >= level do
				stack[#stack].end_line = lnum - 1
				table.remove(stack)
			end

			stack[#stack]:add_child(section)
			table.insert(stack, section)
		end
	end

	-- Cap off the remaining sections in the stack
	for i = 2, #stack do
		stack[i].end_line = #lines
	end

	return root
end

function M.get_tree(filepath)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return nil
	end
	local mtime = stat.mtime.sec

	-- Hottest path: a live tree is already in memory and still current.
	local live = live_cache[filepath]
	if live and live.mtime == mtime then
		return live.tree
	end

	load_cache()
	local cached = cache_data[filepath]

	-- Warm path: rehydrate from the on-disk JSON cache, then keep the live
	-- tree so subsequent calls hit the fast path above.
	if cached and cached.mtime == mtime then
		local tree = rehydrate(cached.root, nil)
		live_cache[filepath] = { mtime = mtime, tree = tree }
		return tree
	end

	-- Cold path: reparse on cache miss or mtime change.
	local tree = parse_tree(filepath)
	if tree then
		cache_data[filepath] = {
			mtime = mtime,
			root = dehydrate(tree),
		}
		save_cache()
		live_cache[filepath] = { mtime = mtime, tree = tree }
	end

	return tree
end

function M.invalidate(filepath)
	load_cache()
	if cache_data[filepath] then
		cache_data[filepath] = nil
		save_cache()
	end
	live_cache[filepath] = nil
end

-- Perform arbitrary search traversal down the active tree
function M.search_nodes(tree, query_fn)
	local results = {}
	local function traverse(node)
		if node.type ~= "root" and query_fn(node) then
			table.insert(results, node)
		end
		for _, child in ipairs(node.children) do
			traverse(child)
		end
	end
	traverse(tree)
	return results
end

function M.setup()
	-- Automatically update tree structure locally when saved
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*.zortex",
		callback = function(args)
			-- A save changes mtime; drop the stale live tree so get_tree
			-- rebuilds it from the new file contents.
			live_cache[args.file] = nil
			M.get_tree(args.file)
		end,
	})
end

return M
