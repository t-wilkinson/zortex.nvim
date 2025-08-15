-- services/objective.lua
local M = {}

local Events = require("zortex.core.event_bus")
local Doc = require("zortex.core.document_manager")
local ProjectService = require("zortex.services.project_service")
local AreaService = require("zortex.services.area_service")
local parser = require("zortex.utils.parser")
local constants = require("zortex.constants")

-- Parse OKR file and extract objectives
function M.get_objectives()
	local doc = Doc.get_file(constants.FILES.OKR)

	if not doc then
		return {}
	end

	return M._parse_objectives_from_document(doc)
end

-- Update OKR progress based on project completions
function M.update_progress()
	local objectives = M.get_objectives()
	local updates = {}

	for _, objective in ipairs(objectives) do
		local progress = M._calculate_objective_progress(objective)

		-- Check if objective is complete
		local was_complete = objective.completed
		local is_complete = progress.completed_krs == progress.total_krs and progress.total_krs > 0

		if is_complete and not was_complete then
			-- Complete objective
			AreaService.complete_objective(objective.id, {
				time_horizon = objective.span,
				created_date = objective.created_date,
				area_links = objective.area_links,
			})

			Events.emit("objective:completed", {
				objective = objective,
				xp_awarded = M._calculate_objective_xp(objective),
			})
		end

		table.insert(updates, {
			line = objective.line_num,
			progress = progress,
			complete = is_complete,
		})
	end

	-- Apply updates to buffer
	M._apply_progress_updates(updates)

	return #updates
end

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

-- Get objective statistics
function M.get_stats()
	local objectives = M.get_objectives()
	local stats = {
		total = #objectives,
		completed = 0,
		by_span = {},
		by_year = {},
	}

	for _, obj in ipairs(objectives) do
		-- Count completed
		if obj.completed then
			stats.completed = stats.completed + 1
		end

		-- By span
		stats.by_span[obj.span] = stats.by_span[obj.span] or { total = 0, completed = 0 }
		stats.by_span[obj.span].total = stats.by_span[obj.span].total + 1
		if obj.completed then
			stats.by_span[obj.span].completed = stats.by_span[obj.span].completed + 1
		end

		-- By year
		stats.by_year[obj.year] = stats.by_year[obj.year] or { total = 0, completed = 0 }
		stats.by_year[obj.year].total = stats.by_year[obj.year].total + 1
		if obj.completed then
			stats.by_year[obj.year].completed = stats.by_year[obj.year].completed + 1
		end
	end

	stats.completion_rate = stats.total > 0 and (stats.completed / stats.total) or 0

	return stats
end

-- Private helper functions
function M._parse_objectives_from_document(doc)
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
			local attrs = parser.parse_attributes(section.raw_text, {
				created = { type = "date" },
				done = { type = "date" },
			})

			if attrs.created then
				current_objective.created_date = os.time(attrs.created)
			end

			if attrs.done then
				current_objective.completed = true
				current_objective.completed_date = os.time(attrs.done)
			end

			-- Extract area links from next line or section content
			-- This would need to look at the actual buffer lines
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
	local projects = {}
	local all_links = parser.extract_all_links(text)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = parser.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				-- Look for project links (not area links)
				local first = parsed.components[1]
				if first.type == "article" and first.text ~= "A" and first.text ~= "Areas" then
					table.insert(projects, first.text)
				end
			end
		end
	end

	return projects
end

function M._calculate_objective_progress(objective)
	local completed_krs = 0
	local total_krs = #objective.key_results

	for _, kr in ipairs(objective.key_results) do
		-- Check if all linked projects are complete
		local all_complete = true
		-- for _, project_name in ipairs(kr.linked_projects) do
		-- 	if not ProjectService.is_project_completed(project_name) then
		-- 		all_complete = false
		-- 		break
		-- 	end
		-- end

		if all_complete and #kr.linked_projects > 0 then
			completed_krs = completed_krs + 1
		end
	end

	return {
		completed_krs = completed_krs,
		total_krs = total_krs,
		percentage = total_krs > 0 and (completed_krs / total_krs * 100) or 0,
	}
end

function M._calculate_objective_xp(objective)
	local base_xp = require("zortex.xp.core").calculate_objective_xp(objective.span, objective.created_date)
	return base_xp
end

function M._apply_progress_updates(updates)
	-- This would update the OKR buffer with progress information
	-- For now, we'll emit an event
	Events.emit("objectives:progress_updated", {
		updates = updates,
	})
end

return M
