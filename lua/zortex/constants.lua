-- constants.lua - Shared constants for Zortex
local M = {}

-- File paths (relative to notes_dir)
M.FILES = {
	-- Core user files
	CALENDAR = "calendar.zortex",
	PROJECTS = "projects.zortex",
	AREAS = "areas.zortex",
	OKR = "okr.zortex",
	DIGEST = "digest.zortex",
	PROJECTS_ARCHIVE = "z/archive.projects.zortex",

	-- User library
	USER_LIBRARY = "z",

	-- System library
	SYSTEM_LIBRARY = ".z",

	-- State files live in .z/<name>.json (core/state): link_index,
	-- search_history, xp_state, notifications_state. Logs: .z/zortex.log
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

-- Section hierarchy: ONE structural level scale used everywhere (tree building,
-- section ends, navigation, breadcrumbs). Lower number = higher in the hierarchy.
--   ARTICLE      -> 0
--   HEADING      -> 1..6 (number of #)
--   BOLD_HEADING -> 7
--   LABEL        -> 8 + indent (indented labels nest under less-indented ones)
--   TAG / TEXT   -> not structural (100 / 999)
M.SECTION_HIERARCHY = {
	levels = {
		[M.SECTION_TYPE.ARTICLE] = 0,
		[M.SECTION_TYPE.BOLD_HEADING] = 7,
		[M.SECTION_TYPE.LABEL] = 8,
		[M.SECTION_TYPE.TAG] = 100,
		[M.SECTION_TYPE.TEXT] = 999,
	},

	-- Structural level for a section type. `heading_level` is the # count for
	-- headings, `indent` the leading whitespace width for labels.
	get_priority = function(section_type, heading_level, indent)
		if section_type == M.SECTION_TYPE.HEADING then
			return math.min(math.max(heading_level or 1, 1), 6)
		elseif section_type == M.SECTION_TYPE.LABEL then
			return M.SECTION_HIERARCHY.levels[section_type] + (indent or 0)
		end
		return M.SECTION_HIERARCHY.levels[section_type] or 999
	end,

	-- Check if parent can contain child
	can_contain = function(parent_type, parent_level, child_type, child_level)
		local parent_priority = M.SECTION_HIERARCHY.get_priority(parent_type, parent_level)
		local child_priority = M.SECTION_HIERARCHY.get_priority(child_type, child_level)
		return parent_priority < child_priority
	end,
}

-- Tag that marks a standalone project article (a line "@P" in the file header),
-- and the tag that marks archived files (excluded from link resolution).
M.PROJECT_TAG = "P"
M.ARCHIVE_TAG = "Archive"

-- Size -> points. Tasks use xs..xl; projects may also use the larger sizes.
-- Unsized tasks count as DEFAULT_TASK_SIZE. An explicit project @size(...)
-- overrides the sum of its tasks.
M.SIZE_POINTS = {
	xs = 1,
	sm = 2,
	md = 3,
	lg = 5,
	xl = 8,
	epic = 13,
	legendary = 21,
	mythic = 34,
	ultimate = 55,
}
M.DEFAULT_TASK_SIZE = "md"

-- Patterns for parsing
M.PATTERNS = {
	-- Sections
	ARTICLE_TITLE = "^@@(.+)",
	HEADING = "^(#+)%s+(.+)",
	HEADING_LEVEL = "^(#+)",
	BOLD_HEADING = "^%*%*([^*]+)%*%*:?%s*$",
	LABEL = "^([^:]+):$",
	TAG_LINE = "^@%w+",

	-- Tasks
	TASK = "^(%s*)%-%s*%[(.)]%s*(.+)$", -- indent, status, text
	TASK_CHECKBOX = "^%s*%-%s*%[([%sxX])%]",
	TASK_TEXT = "^%s*%-%s*%[.%]%s+(.+)",
	TASK_STATUS_KEY = "%s*%[([%w_]+)%]%s*$",

	-- Attributes
	ATTRIBUTE = "@(%w+)%(([^)]+)%)",
	ATTRIBUTE_BARE = "@(%w+)",

	-- Links
	LINK = "%[([^%]]+)%]",
	FOOTNOTE = "%[%^([A-Za-z0-9_.-]+)%]",
	FOOTNOTE_DEF = "^%[%^([A-Za-z0-9_.-]+)%]:%s*",
	MARKDOWN_LINK = "%[([^%]]*)%]%(([^%)]+)%)",
	URL = "https?://[^%s%]%)};]+",
	FILEPATH = "([~%.]/[^%s]+)",

	-- Dates and times
	DATE_YMD = "(%d%d%d%d)%-(%d%d?)%-(%d%d?)", -- YYYY-MM-DD
	DATE_MDY = "(%d%d?)%-(%d%d?)%-(%d%d%d%d)", -- MM-DD-YYYY
	TIME_24H = "(%d%d?):(%d%d)", -- HH:MM
	TIME_AMPM = "(%d%d?):(%d%d)%s*([ap]m)", -- HH:MMam, HH:MM pm
	DATETIME_YMD = "(%d%d%d%d%-%d%d?%-%d%d?)%s+(%d%d?:%d%d)", -- YYYY-MM-DD HH:MM, YYYY-MM-DD HH:MM am
	DATETIME_MDY = "(%d%d-%d%d-%d%d%d%d)%s+(.+)", -- MM-DD-YYYY HH:MM, MM-DD-YYYY HH:MM am

	-- calendar.zortex
	CALENDAR_DATE_HEADING = "^(%d%d%d%d)-(%d%d)%-(%d%d)%:$",
	CALENDAR_ENTRY_PREFIX = "^%s+%-? (.+)$",
	CALENDAR_TIME_PREFIX = "^%s*(%d%d?:%d%d)%s+(.+)$",
	CALENDAR_TIME_RANGE = "^%s*(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)%s+(.+)$",

	-- okr.zortex (matched against heading text, attributes already stripped)
	OBJECTIVE = "^(%w+)%-(%d%d%d%d)%-(%w+)%s+(.+)$", -- "3M-2026-Q1 Title"
	OBJECTIVE_LEGACY = "^(%w+) (%d%d%d%d) (%d%d?) (.+)$", -- "3M 2026 01 Title"
	KEY_RESULT = "^%s*%-%s*KR(%d*)[%-:]?%s*(.*)$", -- "- KR1: [ ] text", "- KR-text"
}

M.TASK_MARKS = {
	TODO = " ",
	COMPLETED = "x",
}

-- Task status definitions
M.TASK_SYMBOL = {
	[" "] = "  ",
	-- ["."] = { symbol = ".", name = "in_progress", tags = { "@inprogress", "@wip" } },
	-- ["o"] = { symbol = "o", name = "ongoing", tags = { "@ongoing" } },
	["x"] = "✓",
	["X"] = "✓",
	-- ["-"] = { symbol = "-", name = "cancelled", tags = { "@cancelled" } },
	-- ["?"] = { symbol = "?", name = "unclear", tags = { "@unclear" } },
	-- ["*"] = { symbol = "*", name = "delegated", tags = { "@delegated" } },
	-- ["l"] = { symbol = "l", name = "later", tags = { "@later" } },
	-- ["L"] = { symbol = "L", name = "later", tags = { "@later" } },
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

	-- Skill tree
	SKILL_LEVEL_1_3 = "ZortexSkillLevel1",
	SKILL_LEVEL_4_6 = "ZortexSkillLevel2",
	SKILL_LEVEL_7_9 = "ZortexSkillLevel3",
	SKILL_LEVEL_10_PLUS = "ZortexSkillLevel4",
	PROGRESS_BAR = "ZortexProgressBar",
}

M.SEARCH_MODES = {
	SECTION = "section",
	ARTICLE = "article",
	TASK = "task",
	ALL = "all",
}

return M
