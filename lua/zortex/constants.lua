-- constants.lua - Centralized constants for Zortex with normalized section hierarchy
local M = {}

-- File names
M.FILES = {
	CALENDAR = "calendar.zortex",
	PROJECTS = "projects.zortex",
	AREAS = "areas.zortex",
	OKR = "okr.zortex",

	-- User library
	USER_LIBRARY = "z",
	ARCHIVE_PROJECTS = "z/archive.projects.zortex",

	-- System library
	SYSTEM_LIBRARY = ".z",
	XP_STATE_DATA = ".z/xp_state.json",
	TASK_STATE_DATA = ".z/task_state.json",
	ARCHIVE_TASK_STATE = ".z/archive.task_state.json",
}

-- Core patterns
M.PATTERNS = {
	-- Task patterns
	TASK_PREFIX = "^%s*%-",
	TASK_UNCHECKED = "^%s*%- %[ %]",
	TASK_STATUS_KEY = "^%s*%- (%[.%])",
	TASK_TEXT = "^%s*%- %[.%] (.+)$",
	TASK_CHECKBOX = "^%s*%- %[(.)%]",

	-- Section patterns (in hierarchical order)
	ARTICLE_TITLE = "^@@(.+)",
	HEADING = "^(#+)%s+(.+)$",
	HEADING_LEVEL = "^#+",
	BOLD_HEADING = "^%*%*(.+)%*%*:$",
	BOLD_HEADING_ALT = "^%*%*(.+):%*%*$",
	LABEL = "^([^%.]+):$", -- No sentence period (". ") allowed

	-- Calendar-specific patterns
	CALENDAR_DATE_HEADING = "^(%d%d)%-(%d%d)%-(%d%d%d%d):$",
	CALENDAR_ENTRY_PREFIX = "^%s+%-? (.+)$",
	CALENDAR_TIME_PREFIX = "^(%d%d?:%d%d)%s+(.+)$",
	CALENDAR_TIME_RANGE = "^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$",

	DATE_YMD = "^(%d%d%d%d)%-(%d%d)%-(%d%d)$", -- YYYY-MM-DD
	DATE_MDY = "^(%d%d)%-(%d%d)%-(%d%d%d%d)$", -- MM-DD-YYYY
	DATETIME_YMD = "^(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$", -- YYYY-MM-DD HH:MM, YYYY-MM-DD HH:MM am
	DATETIME_MDY = "^(%d%d-%d%d-%d%d%d%d)%s+(.+)$", -- MM-DD-YYYY HH:MM, MM-DD-YYYY HH:MM am
	TIME_24H = "^(%d%d?):(%d%d)$", -- HH:MM
	TIME_AMPM = "^(%d%d?):(%d%d)%s*([ap]m)$", -- HH:MMam, HH:MM pm

	-- Link patterns
	LINK = "%[([^%]]+)%]",
	MARKDOWN_LINK = "%[([^%]]*)%]%(([^%)]+)%)",
	FOOTNOTE = "%[%^([A-Za-z0-9_.-]+)%]",
	FOOTNOTE_DEF = "^%[%^([A-Za-z0-9_.-]+)%]:%s*",
	URL = "https?://[^%s%]%)};]+",
	FILEPATH = "([~%.]/[^%s]+)",

	-- Other patterns
	TAG_LINE = "^@[^@]",
	OKR_DATE = "^## ([%w]+) (%d+) (%d+) (.+)$",
	KEY_RESULT = "^%s*- KR%-",
}

-- Section types with hierarchical priorities
-- Lower numbers = higher priority (can contain higher numbers)
M.SECTION_TYPE = {
	ARTICLE = 1, -- Highest priority, contains all
	HEADING = 2, -- Variable priority based on level (1-6)
	BOLD_HEADING = 7, -- After all headings, before labels
	LABEL = 8, -- Lowest priority section type
	TAG = 9, -- Tags don't create sections, just markers
	TEXT = 10, -- Plain text, not a section header
}

-- Section hierarchy helper
M.SECTION_HIERARCHY = {
	-- Returns effective priority for comparison
	-- Articles always have priority 1
	-- Headings have priority 2-7 based on level
	-- Bold headings have priority 8
	-- Labels have priority 9
	get_priority = function(section_type, heading_level)
		if section_type == M.SECTION_TYPE.ARTICLE then
			return 1
		elseif section_type == M.SECTION_TYPE.HEADING then
			-- Heading level 1 = priority 2, level 6 = priority 7
			return 1 + (heading_level or 1)
		elseif section_type == M.SECTION_TYPE.BOLD_HEADING then
			return 8
		elseif section_type == M.SECTION_TYPE.LABEL then
			return 9
		else
			return 999 -- Non-section types
		end
	end,

	-- Check if section A can contain section B
	can_contain = function(type_a, level_a, type_b, level_b)
		local priority_a = M.SECTION_HIERARCHY.get_priority(type_a, level_a)
		local priority_b = M.SECTION_HIERARCHY.get_priority(type_b, level_b)
		return priority_a < priority_b
	end,
}

-- Task status definitions
M.TASK_STATUS = {
	[" "] = { symbol = " ", name = "todo", tags = { "@todo" } },
	["."] = { symbol = ".", name = "in_progress", tags = { "@inprogress", "@wip" } },
	["o"] = { symbol = "o", name = "ongoing", tags = { "@ongoing" } },
	["x"] = { symbol = "x", name = "done", tags = { "@done" } },
	["-"] = { symbol = "-", name = "cancelled", tags = { "@cancelled" } },
	["?"] = { symbol = "?", name = "unclear", tags = { "@unclear" } },
	["*"] = { symbol = "*", name = "delegated", tags = { "@delegated" } },
}

-- Highlight groups
M.HIGHLIGHTS = {
	SKILL_LEVEL_1_3 = "DiagnosticWarn",
	SKILL_LEVEL_4_6 = "DiagnosticInfo",
	SKILL_LEVEL_7_9 = "DiagnosticOk",
	SKILL_LEVEL_10_PLUS = "DiagnosticHint",
	PROGRESS_BAR = "IncSearch",
	PROGRESS_BG = "NonText",
}

return M
