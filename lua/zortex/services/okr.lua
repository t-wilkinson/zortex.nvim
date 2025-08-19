-- services/objective.lua
local M = {}

local parser = require("zortex.utils.parser")
local workspace = require("zortex.core.workspace")

-- Get current (incomplete) objectives
function M.get_current_objectives()
	local all_objectives = M.get_objectives()
	local current = {}

	for _, obj in ipairs(all_objectives) do
		if not obj.completed then
			table.insert(current, obj)
		end
	end

	return current
end

-- Get key result that links to project_link
function M.get_key_results(project_link)
	local key_results = {}
	local objectives = {} -- also return matching objective

	local all_objectives = M.get_objectives()
	for _, objective in ipairs(all_objectives) do
		for _, key_result in objective.key_results do
			for _, linked_project in key_result.linked_projects do
				if project_link == linked_project.full_match_text then
					table.insert(key_results, key_result)
					table.insert(objectives, objective)
				end
			end
		end
	end

	return key_results, objectives
end

-- Get objectives
function M.get_objectives()
	local doc = workspace.okr()
	local objectives = {}
	local current_objective = nil

	-- Walk through document sections
	local function process_section(section)
		-- Check if this is an objective heading
		local okr_date = parser.parse_okr_date(section.raw_text or section.text)
		if okr_date then
			-- Save previous objective
			if current_objective then
				table.insert(objectives, current_objective)
			end

			-- Create new objective
			current_objective = {
				id = M._generate_objective_id(okr_date),
				span = okr_date.span,
				year = okr_date.year,
				month = okr_date.month,
				title = okr_date.title,
				line_num = section.start_line,
				key_results = {},
				area_links = {},
				completed = false,
				created_date = nil,
			}

			-- Extract metadata from section
			local attrs = parser.parse_attributes(section.raw_text or section.text, {
				created = { type = "date" },
				done = { type = "date" },
				area = { type = "area" },
				a = "area",
			})

			if attrs.created then
				current_objective.created_date = os.time(attrs.created)
			end

			if attrs.done then
				current_objective.completed = true
				current_objective.completed_date = os.time(attrs.done)
			end

			if attrs.area then
				for _, area_obj in ipairs(attrs.area) do
					table.insert(current_objective.area_links, area_obj.path)
				end
			end
		end

		-- Check for key results in tasks
		if current_objective then
			for _, task in ipairs(section.tasks) do
				if task.text:match("^KR%-") then
					local kr = {
						text = task.text:gsub("^KR%-", ""),
						line_num = task.line,
						completed = task.completed,
						linked_projects = M._extract_project_links(task.text),
					}
					table.insert(current_objective.key_results, kr)
				end
			end
		end

		-- Process children
		for _, child in ipairs(section.children) do
			process_section(child)
		end
	end

	if doc.sections then
		process_section(doc.sections)
	end

	-- Add last objective
	if current_objective then
		table.insert(objectives, current_objective)
	end

	return objectives
end

function M._generate_objective_id(date_info)
	return string.format(
		"%s_%d_%d_%s",
		date_info.span,
		date_info.year,
		date_info.month,
		date_info.title:gsub("[^%w]", "_")
	)
end

function M._extract_project_links(text)
	local project_links = {}
	local all_links = parser.extract_all_links(text)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			if string.sub(link_info.full_match_text, 1, 2) == "[P" then
				project_links[link_info.full_match_text] = link_info
			end
		end
	end

	return project_links
end

return M
