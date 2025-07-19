-- stores/archive.lua - Archive store for project headings
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-- Create the store instance
local store = BaseStore:new(".archive_cache.json")

-- Override init_empty
function store:init_empty()
	self.data = {
		headings = {}, -- Hierarchical heading structure
		last_updated = nil,
		file_mtime = nil,
	}
	self.loaded = true
end

-- =============================================================================
-- Archive Loading
-- =============================================================================

-- Load and parse the archive file
function M.load()
	local archive_path = fs.get_file_path(constants.FILES.ARCHIVE_PROJECTS)
	if not archive_path or not fs.file_exists(archive_path) then
		return false
	end

	-- Check if we need to reload
	local stat = vim.loop.fs_stat(archive_path)
	local mtime = stat and stat.mtime and stat.mtime.sec or 0

	store:ensure_loaded()

	-- Use cache if file hasn't changed
	if store.data.file_mtime == mtime and store.data.headings then
		return true
	end

	-- Parse the archive file
	local lines = fs.read_lines(archive_path)
	if not lines then
		return false
	end

	-- Build heading structure
	local headings = M._parse_headings(lines)

	-- Update store
	store.data = {
		headings = headings,
		last_updated = os.time(),
		file_mtime = mtime,
		file_path = archive_path,
	}

	store:save()
	return true
end

-- Parse headings into hierarchical structure
function M._parse_headings(lines)
	local headings = {}
	local stack = {} -- Stack to track parent headings

	for lnum, line in ipairs(lines) do
		local heading = parser.parse_heading(line)
		if heading then
			-- Strip attributes to get clean text
			local clean_text = parser.parse_attributes(heading.text, {}).text or heading.text

			local heading_info = {
				text = clean_text,
				raw_text = heading.text,
				level = heading.level,
				lnum = lnum,
				children = {},
			}

			-- Find parent in stack
			while #stack > 0 and stack[#stack].level >= heading.level do
				table.remove(stack)
			end

			if #stack > 0 then
				-- Add as child to parent
				table.insert(stack[#stack].children, heading_info)
			else
				-- Top-level heading
				table.insert(headings, heading_info)
			end

			-- Add to stack
			table.insert(stack, heading_info)
		end
	end

	return headings
end

-- =============================================================================
-- Search Functions
-- =============================================================================

-- Search for headings matching a pattern
function M.search_headings(pattern, case_sensitive)
	M.load()

	local results = {}
	local search_pattern = case_sensitive and pattern or pattern:lower()

	local function search_recursive(headings, parent_path)
		for _, heading in ipairs(headings) do
			local search_text = case_sensitive and heading.text or heading.text:lower()

			if search_text:find(search_pattern, 1, true) then
				local path = vim.deepcopy(parent_path or {})
				table.insert(path, heading)

				table.insert(results, {
					heading = heading,
					path = path,
					lnum = heading.lnum,
					text = heading.text,
				})
			end

			-- Search children
			if heading.children and #heading.children > 0 then
				local path = vim.deepcopy(parent_path or {})
				table.insert(path, heading)
				search_recursive(heading.children, path)
			end
		end
	end

	search_recursive(store.data.headings)
	return results
end

-- Get all headings as flat list
function M.get_all_headings()
	M.load()

	local results = {}

	local function flatten_recursive(headings, parent_path)
		for _, heading in ipairs(headings) do
			local path = vim.deepcopy(parent_path or {})
			table.insert(path, heading)

			table.insert(results, {
				heading = heading,
				path = path,
				lnum = heading.lnum,
				text = heading.text,
				level = heading.level,
			})

			if heading.children and #heading.children > 0 then
				flatten_recursive(heading.children, path)
			end
		end
	end

	flatten_recursive(store.data.headings)
	return results
end

-- Get heading at specific line
function M.get_heading_at_line(lnum)
	M.load()

	local function find_recursive(headings)
		for _, heading in ipairs(headings) do
			if heading.lnum == lnum then
				return heading
			end
			if heading.children then
				local found = find_recursive(heading.children)
				if found then
					return found
				end
			end
		end
		return nil
	end

	return find_recursive(store.data.headings)
end

-- Force reload
function M.reload()
	store.data.file_mtime = nil
	return M.load()
end

return M
