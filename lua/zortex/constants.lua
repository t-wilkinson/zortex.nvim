-- constants.lua - Shared constants for Zortex
local M = {}

-- File paths (relative to notes_dir)
M.FILES = {
	-- Core user files
	CALENDAR = "calendar.zortex",
	PROJECTS = "projects.zortex",
	AREAS = "areas.zortex",
	OKR = "okr.zortex",
	PROJECTS_ARCHIVE = "z/archive.projects.zortex",

	-- User library
	USER_LIBRARY = "z",

	-- System library
	SYSTEM_LIBRARY = ".z",

	-- State files
	XP_STATE_DATA = ".z/xp_state.json",
	TASK_STATE_DATA = ".z/task_state.json",
	ARCHIVE_TASK_STATE = ".z/archive.task_state.json",
	CALENDAR_STATE = ".z/calendar_state.json",
	TIMER_STATE = ".z/timer_state.json",
	NOTIFICATIONS_STATE = ".z/notifications_state.json",
	LOG = ".z/logs",

	-- History files
	SEARCH_HISTORY = ".z/search_history.json",
	COMMAND_HISTORY = ".z/command_history.json",
}

-- Section types
M.SECTION_TYPE = {
	ARTICLE = "article",
	HEADING = "heading",
	BOLD_HEADING = "bold_heading",
	LABEL = "label",
	TAG = "tag",
	TEXT = "text",
}

-- Section hierarchy and priorities (lower number = higher priority)
M.SECTION_HIERARCHY = {
	priorities = {
		[M.SECTION_TYPE.ARTICLE] = 10,
		[M.SECTION_TYPE.HEADING] = {
			[1] = 20,
			[2] = 30,
			[3] = 40,
			[4] = 50,
			[5] = 60,
			[6] = 70,
		},
		[M.SECTION_TYPE.BOLD_HEADING] = 80,
		[M.SECTION_TYPE.LABEL] = 90,
		[M.SECTION_TYPE.TAG] = 100,
		[M.SECTION_TYPE.TEXT] = 999,
	},

	-- Get priority for a section type and level
	get_priority = function(section_type, heading_level)
		local priorities = M.SECTION_HIERARCHY.priorities

		if section_type == M.SECTION_TYPE.HEADING and heading_level then
			return priorities[section_type][heading_level] or 999
		else
			return priorities[section_type] or 999
		end
	end,

	-- Check if parent can contain child
	can_contain = function(parent_type, parent_level, child_type, child_level)
		local parent_priority = M.SECTION_HIERARCHY.get_priority(parent_type, parent_level)
		local child_priority = M.SECTION_HIERARCHY.get_priority(child_type, child_level)
		return parent_priority < child_priority
	end,
}

-- Patterns for parsing
M.PATTERNS = {
	-- Sections
	ARTICLE_TITLE = "^@@(.+)",
	HEADING = "^(#+)%s+(.+)",
	HEADING_LEVEL = "^(#+)",
	BOLD_HEADING = "^%*%*([^*]+)%*%*:?%s*$",
	BOLD_HEADING_ALT = "^__([^_]+)__:?%s*$",
	LABEL = "^([^:]+):$",
	TAG_LINE = "^@%w+",

	-- Tasks
	TASK_CHECKBOX = "^%s*%-%s*%[([%sxX])%]",
	TASK_TEXT = "^%s*%-%s*%[.%]%s+(.+)",
	TASK_STATUS_KEY = "%s*%[([%w_]+)%]%s*$",

	-- Attributes
	ATTRIBUTE = "@(%w+)%(([^)]+)%)",
	ATTRIBUTE_BARE = "@(%w+)",

	-- Links
	LINK = "%[([^%]]+)%]",
	FOOTNOTE = "%[%^([A-Za-z0-9_.-]+)%]",
	MARKDOWN_LINK = "%[([^%]]*)%]%(([^%)]+)%)",
	URL = "https?://[^%s%]%)};]+",

	-- Dates and times
	DATE_YMD = "(%d%d%d%d)%-(%d%d?)%-(%d%d?)",
	DATE_MDY = "(%d%d?)%-(%d%d?)%-(%d%d%d%d)",
	TIME_24H = "(%d%d?):(%d%d)",
	TIME_AMPM = "(%d%d?):(%d%d)%s*([ap]m)",
	DATETIME_YMD = "(%d%d%d%d%-%d%d?%-%d%d?)%s+(%d%d?:%d%d)",

	-- calendar.zortex
	CALENDAR_DATE_HEADING = "^(%d%d)%-(%d%d)%-(%d%d%d%d):$",
	CALENDAR_ENTRY_PREFIX = "^%s+%-? (.+)$",
	CALENDAR_TIME_PREFIX = "^(%d%d?:%d%d)%s+(.+)$",
	CALENDAR_TIME_RANGE = "^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$",

	-- okr.zortex
	OKR_DATE = "^## ([%w]+) (%d+) (%d+) (.+)$",
}

-- Task status definitions
M.TASK_STATUS = {
	TODO = { symbol = " ", name = "To Do", color = "Comment" },
	DOING = { symbol = "◐", name = "In Progress", color = "DiagnosticWarn" },
	WAITING = { symbol = "⏸", name = "Waiting", color = "DiagnosticInfo" },
	DONE = { symbol = "✓", name = "Done", color = "DiagnosticOk" },
	CANCELLED = { symbol = "✗", name = "Cancelled", color = "DiagnosticError" },
	DELEGATED = { symbol = "→", name = "Delegated", color = "DiagnosticHint" },
}

-- Time horizons
M.TIME_HORIZONS = {
	DAILY = "daily",
	WEEKLY = "weekly",
	MONTHLY = "monthly",
	QUARTERLY = "quarterly",
	YEARLY = "yearly",
	FIVE_YEAR = "5year",
}

-- Calendar view modes
M.CALENDAR_MODES = {
	MONTH = "month",
	WEEK = "week",
	DAY = "day",
	AGENDA = "agenda",
}

-- XP tier definitions
M.XP_TIERS = {
	BRONZE = { name = "Bronze", min_level = 1 },
	SILVER = { name = "Silver", min_level = 5 },
	GOLD = { name = "Gold", min_level = 10 },
	PLATINUM = { name = "Platinum", min_level = 15 },
	DIAMOND = { name = "Diamond", min_level = 20 },
	MASTER = { name = "Master", min_level = 30 },
}

-- Highlight groups
M.HIGHLIGHTS = {
	-- Sections
	ARTICLE_TITLE = "ZortexArticleTitle",
	HEADING1 = "ZortexHeading1",
	HEADING2 = "ZortexHeading2",
	HEADING3 = "ZortexHeading3",
	HEADING4 = "ZortexHeading4",
	HEADING5 = "ZortexHeading5",
	HEADING6 = "ZortexHeading6",
	BOLD_HEADING = "ZortexBoldHeading",
	LABEL = "ZortexLabel",
	TAG = "ZortexTag",

	-- Tasks
	TASK_TODO = "ZortexTaskTodo",
	TASK_DONE = "ZortexTaskDone",
	TASK_CANCELLED = "ZortexTaskCancelled",

	-- Links
	LINK = "ZortexLink",
	LINK_BROKEN = "ZortexLinkBroken",

	-- Attributes
	ATTRIBUTE_KEY = "ZortexAttributeKey",
	ATTRIBUTE_VALUE = "ZortexAttributeValue",

	-- XP
	XP_GAIN = "ZortexXPGain",
	XP_LEVEL = "ZortexXPLevel",
}

return M
