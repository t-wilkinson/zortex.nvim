-- File parsing for Zortex XP system
local M = {}

local Path = require("plenary.path")

-- Detect file type from filename
function M.detect_file_type(filepath)
	local filename = vim.fn.fnamemodify(filepath, ":t:r")

	-- Check explicit file types
	local types = {
		"visions",
		"objectives",
		"keyresults",
		"projects",
		"areas",
		"resources",
		"habits",
	}

	for _, type in ipairs(types) do
		if filename:match(type) then
			return type
		end
	end

	-- Check for specific patterns
	if filename:match("project") then
		return "projects"
	elseif filename:match("habit") then
		return "habits"
	elseif filename:match("resource") then
		return "resources"
	end

	return "notes" -- Default type
end

-- Parse a zortex file
function M.parse_file(filepath)
	local content = Path:new(filepath):read()
	if not content then
		return nil
	end

	local file_type = M.detect_file_type(filepath)
	local file_data = {
		type = file_type,
		filepath = filepath,
		articles = {},
		current_article = nil,
		tasks = {},
		projects = {},
		objectives = {},
		key_results = {},
		visions = {},
		areas = {},
		resources = {},
		habits = {},
		items = {}, -- All items
	}

	local current_item = nil
	local item_lines = 0
	local in_task = false
	local task_metadata = {}
	local line_number = 0

	for line in content:gmatch("[^\r\n]+") do
		line_number = line_number + 1

		-- Article headers (@@)
		if line:match("^@@") then
			local article_name = line:match("^@@%s*(.+)")
			file_data.current_article = article_name
			table.insert(file_data.articles, article_name)

			-- Create item based on file type
			current_item = M.create_article_item(file_type, article_name, filepath)
			if current_item then
				M.add_item_to_data(file_data, current_item)
			end

			item_lines = 0

		-- Metadata tags (@)
		elseif line:match("^@") and not line:match("^@@") then
			local tag = line:match("^@(.+)")
			task_metadata = M.parse_metadata_tag(tag, task_metadata)

			-- Also apply to current item
			if current_item then
				M.apply_metadata_to_item(current_item, tag)
			end

		-- Task patterns
		elseif M.is_task_line(line) then
			-- Apply size heuristic to previous task
			if in_task and current_item and not current_item.size then
				current_item.size = M.get_size_from_lines(item_lines)
			end

			-- Create new task
			current_item = M.create_task_from_line(filepath, line, line_number, file_data)

			-- Apply stored metadata
			for k, v in pairs(task_metadata) do
				current_item[k] = v
			end
			task_metadata = {}

			M.add_item_to_data(file_data, current_item)
			item_lines = 1
			in_task = true

		-- Links
		elseif line:match("%[.+%]") then
			local links = M.extract_links(line)
			if current_item and links then
				for _, link in ipairs(links) do
					table.insert(current_item.links, link)
				end
			end
			if in_task then
				item_lines = item_lines + 1
			end

		-- Resource tracking
		elseif line:match("^%s*%+%s*") then
			local resource = M.parse_resource_line(line, "create")
			if resource then
				resource.article = file_data.current_article
				resource.file = filepath
				M.add_item_to_data(file_data, resource)
			end
		elseif line:match("^%s*%-%s*") and not M.is_task_line(line) then
			local resource = M.parse_resource_line(line, "consume")
			if resource then
				resource.article = file_data.current_article
				resource.file = filepath
				M.add_item_to_data(file_data, resource)
			end

		-- Habit tracking
		elseif line:match("^%s*!") then
			local habit = M.parse_habit_line(line)
			if habit then
				habit.article = file_data.current_article
				habit.file = filepath
				M.add_item_to_data(file_data, habit)
			end

		-- Count lines for size heuristic
		elseif in_task and line:match("^%s+") then
			item_lines = item_lines + 1
		else
			-- Task ended, apply size heuristic
			if in_task and current_item and not current_item.size then
				current_item.size = M.get_size_from_lines(item_lines)
			end
			in_task = false
		end
	end

	-- Final size heuristic
	if in_task and current_item and not current_item.size then
		current_item.size = M.get_size_from_lines(item_lines)
	end

	return file_data
end

-- Check if line is a task
function M.is_task_line(line)
	local patterns = {
		"^%s*%- %[.?%]", -- Checkbox with any single character or empty
		"^%s*%* TODO", -- Org-mode TODO
		"^%s*%* DONE", -- Org-mode DONE
		"^%s*✓", -- Checkmark
		"^%s*◯", -- Circle (pending)
		"^%s*→", -- Arrow (action)
	}

	for _, pattern in ipairs(patterns) do
		if line:match(pattern) then
			return true
		end
	end

	-- Also check for simple list items that might be tasks
	if line:match("^%s*%-") then
		-- Check if it contains action words
		local action_words = { "todo", "fix", "create", "build", "write", "review", "check", "test", "implement" }
		local line_lower = line:lower()
		for _, word in ipairs(action_words) do
			if line_lower:match(word) then
				return true
			end
		end
	end

	return false
end

-- Create task from line
function M.create_task_from_line(filepath, line, line_number, file_data)
	local task = {
		type = "task",
		file = filepath,
		line_number = line_number,
		article = file_data and file_data.current_article,
		links = {},
		completed = false,
	}

	-- Check completion status
	local checkbox_content = line:match("%[(.?)%]")
	if checkbox_content and checkbox_content ~= " " and checkbox_content ~= "" then
		task.completed = true
	elseif line:match("DONE") or line:match("^%s*✓") or line:match("@done") or line:match("@completed") then
		task.completed = true
	end

	-- Extract task text - handle checkbox format specially
	if line:match("^%s*%- %[.?%]") then
		-- Checkbox format
		task.text = line:match("%- %[.?%]%s*(.+)")
	else
		-- Other formats
		task.text = line:gsub("^%s*%- %[.%]%s*", "")
			:gsub("^%s*%* %w+%s*", "")
			:gsub("^%s*✓%s*", "")
			:gsub("^%s*◯%s*", "")
			:gsub("^%s*→%s*", "")
			:gsub("%s*@done.*$", "")
			:gsub("%s*@completed.*$", "")
	end

	-- Trim task text
	if task.text then
		task.text = task.text:gsub("^%s+", ""):gsub("%s+$", "")
	end

	-- Extract inline metadata
	local inline_meta = M.extract_inline_metadata(line)
	for k, v in pairs(inline_meta) do
		-- Don't override the text we extracted
		if k ~= "text" then
			task[k] = v
		end
	end

	-- Mark project tasks
	if filepath:match("project") then
		task.in_project = true
	end

	return task
end

-- Parse metadata tag
function M.parse_metadata_tag(tag, metadata)
	metadata = metadata or {}

	-- Priority
	if tag:match("^p[123]") then
		metadata.priority = tag

	-- Due date
	elseif tag:match("^due%((.+)%)") then
		metadata.due = tag:match("^due%((.+)%)")

	-- Duration
	elseif tag:match("^(%d+%.?%d*)h") then
		metadata.duration = tonumber(tag:match("^(%d+%.?%d*)h"))

	-- Heat
	elseif tag:match("^heat%((.+)%)") then
		metadata.heat = tonumber(tag:match("^heat%((.+)%)"))

	-- Status
	elseif tag:match("^status%((.+)%)") then
		metadata.status = tag:match("^status%((.+)%)")

	-- Repeat
	elseif tag:match("^repeat%((.+)%)") then
		metadata.repeat_type = tag:match("^repeat%((.+)%)")

	-- Size
	elseif tag:match("^(xs|s|m|l|xl)$") then
		metadata.size = tag

	-- Budget
	elseif tag:match("^budget%((.+)%)") then
		local amount = tag:match("^budget%(%$?([%d%.]+)%)")
		metadata.budget = tonumber(amount)

	-- Category
	elseif tag:match("^category%((.+)%)") then
		metadata.category = tag:match("^category%((.+)%)")

	-- Habit
	elseif tag:match("^habit%((.+)%)") then
		metadata.habit = tag:match("^habit%((.+)%)")

	-- Resource
	elseif tag:match("^resource%((.+)%)") then
		metadata.resource = tag:match("^resource%((.+)%)")
	end

	return metadata
end

-- Extract inline metadata from task line
function M.extract_inline_metadata(line)
	local metadata = {}

	-- Size indicators
	if line:match("%((%d+)m%)") then
		local minutes = tonumber(line:match("%((%d+)m%)"))
		metadata.duration = minutes / 60
	elseif line:match("%((%d+%.?%d*)h%)") then
		metadata.duration = tonumber(line:match("%((%d+%.?%d*)h%)"))
	end

	-- Budget
	if line:match("%$([%d%.]+)") then
		metadata.budget = tonumber(line:match("%$([%d%.]+)"))
	end

	-- Priority indicators
	local priority_patterns = {
		"!!!", -- p1
		"!!", -- p2
		"!", -- p3
	}

	for i, pattern in ipairs(priority_patterns) do
		if line:match(pattern) then
			metadata.priority = "p" .. i
			break
		end
	end

	-- Size from keywords
	local size_keywords = {
		{ pattern = "quick", size = "xs" },
		{ pattern = "small", size = "s" },
		{ pattern = "medium", size = "m" },
		{ pattern = "large", size = "l" },
		{ pattern = "huge", size = "xl" },
		{ pattern = "tiny", size = "xs" },
		{ pattern = "big", size = "l" },
	}

	local line_lower = line:lower()
	for _, sk in ipairs(size_keywords) do
		if line_lower:match(sk.pattern) then
			metadata.size = sk.size
			break
		end
	end

	-- Tags at end of line
	local tags = line:match("%s+@(.+)$")
	if tags then
		for tag in tags:gmatch("%S+") do
			metadata = M.parse_metadata_tag(tag, metadata)
		end
	end

	-- Due dates
	local date_patterns = {
		"due:(%d+%-?%d*%-?%d*)",
		"by:(%d+%-?%d*%-?%d*)",
		"deadline:(%d+%-?%d*%-?%d*)",
	}

	for _, pattern in ipairs(date_patterns) do
		local date = line:match(pattern)
		if date then
			metadata.due = date
			break
		end
	end

	-- Categories from hashtags
	local category = line:match("#(%w+)")
	if category then
		metadata.category = category
	end

	-- Extract links (excluding checkboxes)
	local links = M.extract_links(line)
	if #links > 0 then
		metadata.links = links
	end

	return metadata
end

-- Apply metadata to item
function M.apply_metadata_to_item(item, tag)
	local meta = M.parse_metadata_tag(tag)
	for k, v in pairs(meta) do
		item[k] = v
	end
end

-- Extract links from line
function M.extract_links(line)
	local links = {}

	-- First, remove checkbox patterns to avoid false matches
	local cleaned_line = line
		:gsub("%[[ xX~%-]%]", "") -- Remove checkboxes: [ ], [x], [X], [~], [-]
		:gsub("%[%s*%]", "") -- Remove empty brackets with spaces

	-- Now extract actual links
	for link in cleaned_line:gmatch("%[([^%]]+)%]") do
		-- Additional check to ensure it's not a single character checkbox
		if #link > 1 or not link:match("^[xX ~%-]$") then
			table.insert(links, link)
		end
	end

	return links
end

-- Parse resource line
function M.parse_resource_line(line, action)
	local resource_pattern = "^%s*[%+%-]%s*(.+)"
	local text = line:match(resource_pattern)

	if text then
		local amount = 1
		local name = text

		-- Extract amount if specified
		local amount_match = text:match("^(%d+)x?%s+(.+)")
		if amount_match then
			amount = tonumber(amount_match)
			name = text:match("^%d+x?%s+(.+)")
		end

		return {
			type = "resource",
			action = action,
			name = name,
			amount = amount,
			links = {},
		}
	end

	return nil
end

-- Parse habit line
function M.parse_habit_line(line)
	local habit_pattern = "^%s*!%s*(.+)"
	local text = line:match(habit_pattern)

	if text then
		local frequency = "daily" -- default
		local name = text

		-- Extract frequency
		if text:match("^%((%w+)%)%s+(.+)") then
			frequency = text:match("^%((%w+)%)")
			name = text:match("^%(%w+%)%s+(.+)")
		end

		return {
			type = "habit",
			name = name,
			frequency = frequency,
			links = {},
		}
	end

	return nil
end

-- Create article item based on file type
function M.create_article_item(file_type, name, filepath)
	local type_map = {
		visions = "vision",
		objectives = "objective",
		keyresults = "key_result",
		projects = "project",
		areas = "area",
		resources = "resource_collection",
		habits = "habit_collection",
	}

	local item_type = type_map[file_type]
	if not item_type then
		return nil
	end

	return {
		type = item_type,
		name = name,
		file = filepath,
		links = {},
	}
end

-- Add item to appropriate collections
function M.add_item_to_data(file_data, item)
	-- Add to generic items
	table.insert(file_data.items, item)

	-- Add to specific collections
	local collections = {
		task = "tasks",
		project = "projects",
		objective = "objectives",
		key_result = "key_results",
		vision = "visions",
		area = "areas",
		resource = "resources",
		habit = "habits",
	}

	local collection = collections[item.type]
	if collection and file_data[collection] then
		table.insert(file_data[collection], item)
	end
end

-- Get size from line count
function M.get_size_from_lines(lines)
	-- Default size thresholds if config not available
	local thresholds = {
		xl = 20,
		l = 10,
		m = 5,
		s = 3,
		xs = 1,
	}

	-- Try to get from config if available
	local ok, xp = pcall(require, "zortex.xp")
	if ok and xp.get_config then
		local cfg = xp.get_config()
		if cfg and cfg.size_thresholds then
			thresholds = cfg.size_thresholds
		end
	end

	if lines >= thresholds.xl then
		return "xl"
	elseif lines >= thresholds.l then
		return "l"
	elseif lines >= thresholds.m then
		return "m"
	elseif lines >= thresholds.s then
		return "s"
	else
		return "xs"
	end
end

-- Return module
return M
