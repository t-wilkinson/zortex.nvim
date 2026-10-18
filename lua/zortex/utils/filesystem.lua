-- utils/filesystem.lua - File operations for Zortex
local M = {}

local constants = require("zortex.constants")
local Config = require("zortex.config")

-- =============================================================================
-- Path Utilities
-- =============================================================================

function M.get_file_path(filename)
	return Config.notes_dir .. filename
end

function M.joinpath(...)
	local parts = { ... }
	local path = table.concat(parts, "/")
	return path:gsub("//+", "/")
end

function M.ensure_directory(path)
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
end

-- =============================================================================
-- File Reading/Writing
-- =============================================================================

function M.read_lines(filepath)
	local file = io.open(filepath, "r")
	if not file then
		return nil
	end

	local lines = {}
	for line in file:lines() do
		table.insert(lines, line)
	end
	file:close()

	return lines
end

function M.write_lines(filepath, lines)
	M.ensure_directory(filepath)

	local file = io.open(filepath, "w")
	if not file then
		return false
	end

	for _, line in ipairs(lines) do
		file:write(line .. "\n")
	end
	file:close()

	return true
end

function M.file_exists(filepath)
	return vim.fn.filereadable(filepath) == 1
end

-- =============================================================================
-- File Finding
-- =============================================================================

--- Whether a file name is a sync tool's conflict copy: Syncthing's
--- "note.sync-conflict-20261015-143000-ABCDEFG.zortex", or Dropbox's and
--- Nextcloud's "note (… conflicted copy …).zortex". They are not notes: a
--- copy of projects.zortex would be a second @@Projects.
function M.is_conflict_copy(name)
	return name:find(".sync-conflict-", 1, true) ~= nil or name:find("conflicted copy", 1, true) ~= nil
end

--- Every note file under notes_dir (hidden folders and conflict copies left
--- out), optionally filtered by filter_fn(path).
--- opts.conflicts: list the conflict copies instead.
function M.find_all_notes(filter_fn, opts)
	local dir = (opts and opts.dir) or Config.notes_dir
	local pattern = "%" .. Config.extension .. "$"
	local want_conflicts = opts and opts.conflicts or false
	local files = {}

	local function scan_dir(path)
		local scandir = vim.uv.fs_scandir(path)
		if not scandir then
			return
		end

		while true do
			local name, type = vim.uv.fs_scandir_next(scandir)
			if not name then
				break
			end

			local full_path = M.joinpath(path, name)

			if type == "directory" and not name:match("^%.") then
				-- Recursively scan subdirectories
				scan_dir(full_path)
			elseif type == "file" and name:match(pattern) and M.is_conflict_copy(name) == want_conflicts then
				if not filter_fn or filter_fn(full_path) then
					table.insert(files, full_path)
				end
			end
		end
	end

	scan_dir(dir)
	return files
end

-- =============================================================================
-- Special File Access
-- =============================================================================

function M.get_calendar_file()
	return M.get_file_path(constants.FILES.CALENDAR)
end

function M.get_projects_file()
	return M.get_file_path(constants.FILES.PROJECTS)
end

function M.get_okr_file()
	return M.get_file_path(constants.FILES.OKR)
end

function M.get_areas_file()
	return M.get_file_path(constants.FILES.AREAS)
end

function M.get_structure_file()
	return M.get_file_path(constants.FILES.STRUCTURE)
end

function M.get_inbox_file()
	return M.get_file_path(constants.FILES.INBOX)
end

function M.get_reviews_file()
	return M.get_file_path(constants.FILES.REVIEWS)
end

return M
