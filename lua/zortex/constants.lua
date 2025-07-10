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

-- Patterns
M.PATTERNS = {
	-- Task patterns
	TASK_UNCHECKED = "^%s*%- %[ %]",
	TASK_CHECKED = "^%s*%- %[[xX]%]",
	TASK_TEXT = "^%s*%- %[.%] (.+)$",

	-- Heading patterns
	HEADING = "^(#+)%s+(.+)$",
	HEADING_LEVEL = "^#+",

	-- Attribute patterns
	SIZE = "@(%w+)",
	PRIORITY = "@p(%d)",
	IMPORTANCE = "@i(%d)",
	DURATION = "@(%d+)([hm])",
	ESTIMATION = "@est%((%d+)([hm])%)",
	DONE_DATE = "@done%((%d%d%d%d%-%d%d%-%d%d)%)",
	PROGRESS = "@progress%((%d+)/(%d+)%)",
	XP = "@xp%((%d+)%)",
	ID = "@id%(([^)]+)%)",

	-- Link patterns
	LINK = "%[([^%]]+)%]",
	MARKDOWN_LINK = "%[([^%]]*)%]%(([^%)]+)%)",
	FOOTNOTE = "%[%^([A-Za-z0-9_.-]+)%]",
	FOOTNOTE_DEF = "^%[%^([A-Za-z0-9_.-]+)%]:%s*",
	URL = "https?://[^%s%]%)};]+",
	FILEPATH = "([~%.]/[^%s]+)",

	-- Other patterns
	ARTICLE_TITLE = "^@@(.+)",
	BOLD_HEADING = "^%*%*[^%*]+%*%*:?$",
	OKR_DATE = "^## ([%w]+) (%d+) (%d+) (.+)$",
	KEY_RESULT = "^%s*- KR%-",
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
