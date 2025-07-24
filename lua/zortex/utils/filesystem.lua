-- core/filesystem.lua - File operations for Zortex
local M = {}

local constants = require("zortex.constants")
local Config = require("zortex.config")

-- =============================================================================
-- Path Utilities
-- =============================================================================

function M.get_notes_dir()
	local dir = Config.notes_dir
	-- Ensure trailing slash
	if not dir:match("/$") then
		dir = dir .. "/"
	end
	return dir
end

function M.get_file_path(filename)
	local dir = M.get_notes_dir()
	if not dir then
		return nil
	end
	return dir .. filename
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

function M.directory_exists(dirpath)
	return vim.fn.isdirectory(dirpath) == 1
end

-- =============================================================================
-- File Finding
-- =============================================================================

function M.find_files(dir, pattern)
	local files = {}
	local scandir = vim.loop.fs_scandir(dir)
	if not scandir then
		return files
	end

	while true do
		local name, type = vim.loop.fs_scandir_next(scandir)
		if not name then
			break
		end

		if type == "file" and name:match(pattern) then
			local full_path = M.joinpath(dir, name)
			table.insert(files, full_path)
		end
	end

	return files
end

function M.get_all_note_files()
	local dir = M.get_notes_dir()
	if not dir then
		return {}
	end

	local files = {}

	-- Find .zortex files
	for _, file in ipairs(M.find_files(dir, "%.zortex$")) do
		table.insert(files, file)
	end

	-- Find .md files
	for _, file in ipairs(M.find_files(dir, "%.md$")) do
		table.insert(files, file)
	end

	-- Find .txt files
	for _, file in ipairs(M.find_files(dir, "%.txt$")) do
		table.insert(files, file)
	end

	return files
end

-- =============================================================================
-- Special File Access
-- =============================================================================

function M.get_projects_file()
	return M.get_file_path(constants.FILES.PROJECTS)
end

function M.get_archive_file()
	return M.get_file_path(constants.FILES.ARCHIVE_PROJECTS)
end

function M.get_okr_file()
	return M.get_file_path(constants.FILES.OKR)
end

function M.get_areas_file()
	return M.get_file_path(constants.FILES.AREAS)
end

-- =============================================================================
-- Archive File Operations
-- =============================================================================

function M.read_archive()
	local archive_path = M.get_archive_file()
	if not archive_path then
		return nil
	end

	M.ensure_directory(archive_path)

	-- Create file if it doesn't exist
	if not M.file_exists(archive_path) then
		M.write_lines(archive_path, { "@XP(0)", "" })
	end

	return M.read_lines(archive_path)
end

function M.write_archive(lines)
	local archive_path = M.get_archive_file()
	if not archive_path then
		return false
	end

	return M.write_lines(archive_path, lines)
end

-- =============================================================================
-- JSON Operations
-- =============================================================================

function M.read_json(filepath)
	if not M.file_exists(filepath) then
		return nil
	end

	local file = io.open(filepath, "r")
	if not file then
		return nil
	end

	local content = file:read("*all")
	file:close()

	local success, data = pcall(vim.fn.json_decode, content)
	if success and type(data) == "table" then
		return data
	end

	return nil
end

function M.write_json(filepath, data)
	M.ensure_directory(filepath)

	local json_data = vim.fn.json_encode(data)

	local file = io.open(filepath, "w")
	if not file then
		return false
	end

	file:write(json_data)
	file:close()

	return true
end

return M
