# 🔗 Zortex Link System

The Zortex link system provides powerful ways to connect ideas, navigate between documents, and build a personal knowledge graph.

## 🌐 Link Types Overview

Zortex supports multiple link types for different use cases:

1. **Internal Links** - Connect to other Zortex documents
2. **Section Links** - Link to specific sections within documents
3. **Tag Links** - Reference tags across the system
4. **External Links** - Standard URLs and markdown links
5. **Footnotes** - Reference-style links

## 📝 Link Syntax

### Internal Links

Basic article link:

```zortex
[ArticleName]
```

### Section Links

Link to specific sections using forward slashes:

```zortex
[ArticleName/SectionName]
[ArticleName/Section/Subsection]
[ArticleName/Section/Subsection/DeepSection]
```

There are special characters that may begin each link component to look for specific sections:
"": Nothing looks for an article name
`@`: Looks for tags, lines starting with a single "@"
`#`: Looks for headings
`*`: Looks for any text within two astericks `^**text**:$` or `**text**`
`:`: Looks for label sections
`%`: Is a query, that looks for any piece of text within the currently resolve section(s)

Every link component is case insensitive and is a leading match, it tries to match the beggining of the section text.

If a link starts with a section part (one of `@#*:%`) then search all files for each possible section match, and return the results in quickfix. Otherwise, go to the first match.

You can compose the components, with each component searching within the section that the leading link so far links to.

Examples:

```zortex
[ProjectAlpha/Implementation]
[Areas/Technology/Programming/Lua]
[DailyNotes/2024-01-15/Morning Thoughts]
```

### Tag Links

Reference tags with @ prefix:

```zortex
[@productivity]
[@project-management]
```

### External Links

Standard URLs are auto-detected:

```
https://example.com
```

Markdown-style links:

```
[Display Text](https://example.com)
```

### Footnotes

Define footnote references:

```zortex
This needs clarification[^1].

[^1]: This is the footnote content.
```

## 🎯 Link Resolution

### Article Name Resolution

Zortex uses smart article name resolution:

1. **Exact Match**: First tries exact article name
2. **Alias Match**: Checks article aliases (additional @@ lines)
3. **Case Insensitive**: Falls back to case-insensitive search
4. **Fuzzy Match**: Optional fuzzy matching for typos

### Section Resolution

Sections are resolved hierarchically:

```zortex
@@My Project
@@MP

# Overview
## Goals        ← [My Project/Overview/Goals] or [My Project/#Overview/#Goals] or [My Project/##Goals]
### Q1 Targets  ← [My Project/Overview/Goals/Q1 Targets] or [MP/#Q1]
```

Resolution rules:

- Matches are case-insensitive for sections
- Spaces in section names are preserved
- Special characters are included

### Relative Links

Links can be relative to the current document:

```zortex
[/SectionInThisDoc]
[./SiblingSection]
[../ParentSection]
```

## 🚀 Navigation

### Opening Links

Default keybinding: `<leader>zo` or `gx`

Behavior depends on link type:

- **Article links**: Opens the linked document
- **Section links**: Opens document and jumps to section
- **Tag links**: Shows all documents with that tag
- **External links**: Opens in default browser

## 🤖 Auto-completion

The completion system provides intelligent link suggestions:

### Triggering Completion

Type `[` to trigger link completion, showing:

- Recent documents
- Related articles
- Popular sections
- Matching tags

## 🎯 Best Practices

### 4. Tag Organization

Use hierarchical tags:

```zortex
@project/active
@project/completed
@area/technology
@area/health
```
