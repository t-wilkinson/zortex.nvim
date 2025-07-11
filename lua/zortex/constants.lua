-- constants.lua - Centralized constants for Zortex
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
}

-- Core patterns
M.PATTERNS = {
	-- Task patterns
	TASK_PREFIX = "^%s*%-",
	TASK_UNCHECKED = "^%s*%- %[ %]",
	TASK_STATUS_KEY = "^%s*%- (%[.%])",
	TASK_TEXT = "^%s*%- %[.%] (.+)$",
	-- TASK_CHECKBOX = "^%s*[-*%u·]?%s*%[([ xX‑])%]%s+",
	TASK_CHECKBOX = "^%s*%- %[(.)%]",

	-- Heading patterns
	HEADING = "^(#+)%s+(.+)$",
	HEADING_LEVEL = "^#+",

	-- Calendar-specific patterns
	CALENDAR_DATE_HEADING = "^(%d%d)%-(%d%d)%-(%d%d%d%d):$",
	CALENDAR_ENTRY_PREFIX = "^%s+%-? (.+)$",
	CALENDAR_TIME_PREFIX = "^(%d%d?:%d%d)%s+(.+)$",
	CALENDAR_TIME_RANGE = "^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$",

	-- Link patterns
	LINK = "%[([^%]]+)%]",
	MARKDOWN_LINK = "%[([^%]]*)%]%(([^%)]+)%)",
	FOOTNOTE = "%[%^([A-Za-z0-9_.-]+)%]",
	FOOTNOTE_DEF = "^%[%^([A-Za-z0-9_.-]+)%]:%s*",
	URL = "https?://[^%s%]%)};]+",
	FILEPATH = "([~%.]/[^%s]+)",

	-- Other patterns
	ARTICLE_TITLE = "^@@(.+)",
	TAG_LINE = "^@[^@]",
	BOLD_HEADING = "^%*%*[^%*]+%*%*:?$",
	LABEL = "^%w[^:]+:",
	OKR_DATE = "^## ([%w]+) (%d+) (%d+) (.+)$",
	KEY_RESULT = "^%s*- KR%-",
}

M.SECTION_TYPE = {
	ARTICLE = 1,
	TAG = 2,
	HEADING = 3,
	BOLD_HEADING = 4,
	LABEL = 5,
	TEXT = 6,
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
