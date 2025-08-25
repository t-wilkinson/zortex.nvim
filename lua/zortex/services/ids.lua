local workspace = require("zortex.core.workspace")
local Logger = require("zortex.core.logger")

local M = {}

function M.get_all_ids(doc)
	local lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)

	local all_ids = {}
	for _, line in ipairs(lines) do
		for match in string.gmatch(line, "@id%((%w+)%)") do
			table.insert(all_ids, match)
		end
	end

	return all_ids
end

-- Find a task by ID across all workspace documents
-- Returns: task_data, document, line_number
function M.find_task_by_id(task_id)
	if not task_id then
		Logger.warn("tasks", "find_task_by_id called with nil task_id")
		return nil
	end

	Logger.debug("tasks", "Searching for task", { task_id = task_id })

	-- Search in all workspace documents
	local docs_to_search = {
		workspace.projects(),
		workspace.calendar(),
	}

	for _, doc in ipairs(docs_to_search) do
		if doc and doc.sections then
			return false
			-- Get all tasks from document
			-- local ids = M.get_all_ids(doc)

			-- for _, id in ipairs(ids) do
			-- 	if id == task_id then
			-- 		return true
			-- 	end
			-- end
		end
	end

	Logger.debug("tasks", "Task not found", { task_id = task_id })
	return nil
end

return M
