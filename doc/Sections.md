# 📚 Zortex Section-Based Hierarchy System

The section-based hierarchy system is the foundation of document organization in Zortex, providing a flexible yet structured way to organize your knowledge.

## 🏗️ Hierarchy Overview

Zortex documents are organized into a hierarchical structure with clearly defined section types and priorities:

```
@@Article (Priority: 10)
├── # Heading 1 (Priority: 20)
│   ├── ## Heading 2 (Priority: 30)
│   │   ├── ### Heading 3 (Priority: 40)
│   │   │   └── Text content (Priority: 999)
│   │   └── **Bold Heading**: (Priority: 80)
│   │       └── Label: (Priority: 90)
│   └── @tag (Priority: 100)
└── Text content (Priority: 999)
```

## 📋 Section Types

### 1. Article (`@@`)

- **Syntax**: `@@Article Title`
- **Priority**: 10 (highest)
- **Purpose**: Top-level document identifier
- **Special**: Can have multiple aliases

```zortex
@@My Project
@@project-2024-q1
```

### 2. Headings (`#`)

- **Syntax**: `# Heading Text`
- **Priorities**:
  - `#` Level 1: 20
  - `##` Level 2: 30
  - `###` Level 3: 40
  - `####` Level 4: 50
  - `#####` Level 5: 60
  - `######` Level 6: 70
- **Purpose**: Primary content organization

```zortex
# Overview
## Goals
### Q1 Objectives
#### January Tasks
```

### 3. Bold Headings (`**`)

- **Syntax**: `**Bold Section**:`
- **Priority**: 80
- **Purpose**: Emphasis sections, secondary organization

```zortex
**Important Notes**:
This section contains critical information.

**Resources**:
- Book recommendations
- Online courses
```

### 4. Labels

- **Syntax**: `Label Name:`
- **Priority**: 90
- **Purpose**: Metadata, lists, definitions
- **Note**: Must not contain periods or spaces before the colon

```zortex
Prerequisites:
- Basic understanding of hierarchies
- Familiarity with markdown

Status:
In Progress
```

### 5. Tags (`@`)

- **Syntax**: `@tag-name/with-optional-forward-slash-for-hierarchy`
- **Priority**: NA
- **Purpose**: Categorization, indexing, attaches metadata to section
- **Placement**: Beggining of line, usually at beggining of file, after article names. Always directly after a section

```zortex
@productivity
@knowledge-management
@personal-development
```

### 6. Text

- **Priority**: 999 (lowest)
- **Purpose**: Regular content
- **Behavior**: Always contained within higher-priority sections

## 🔄 Hierarchy Rules

### Containment Rules

A section can only contain sections of lower priority (higher number):

✅ **Valid structures**:

```zortex
# Heading 1 (20)
  ## Heading 2 (30)
    **Bold**: (80)
      Label: (90)
        Text content (999)
```

❌ **Invalid structures**:

```zortex
**Bold**: (80)
  # Heading 1 (20)  ← Cannot contain higher priority
```

### Section Boundaries

Sections implicitly end when:

1. A section of equal or higher priority appears
2. The document ends
3. A parent section ends

Example:

```zortex
# Section A
Content for A
## Subsection A.1
Content for A.1
# Section B        ← Ends both A.1 and A
Content for B
```

Code blocks should only be treated as text, and never contain sections.

## 🧭 Navigation

### Section Paths

Sections can be referenced by their path:

```
Article/Heading1/Heading2/BoldSection
```

### Navigation Commands

Navigate between sections at the same level:

- Next section: `]s`
- Previous section: `[s`

Jump to parent section:

- Parent: `[p`

## 🔍 Section Detection

The parser uses these patterns to detect sections:

| Section Type | Pattern               | Example         |
| ------------ | --------------------- | --------------- |
| Article      | `^@@(.+)`             | `@@My Article`  |
| Heading      | `^(#+)\s+(.+)`        | `## Chapter 2`  |
| Bold Heading | `^\*\*([^*]+)\*\*:?$` | `**Summary**:`  |
| Label        | `^([^:]+):$`          | `Dependencies:` |
| Tag          | `^@\w+`               | `@important`    |

## 💡 Best Practices

### 1. Consistent Hierarchy

Maintain logical progression through heading levels:

```zortex
# Project Overview
## Phase 1
### Week 1 Tasks
### Week 2 Tasks
## Phase 2
```

### 2. Semantic Section Types

Use section types for their intended purpose:

- **Headings**: Major content divisions
- **Bold headings**: Contain various label sections
- **Labels**: Lists, properties, definitions
- **Tags**: Cross-cutting concerns

### 3. Article Aliases

Use multiple `@@` lines for different ways to reference the same document:

```zortex
@@Advanced TypeScript Patterns
@@typescript-advanced
@@ts-patterns
```

### 4. Section Spacing

Add blank lines between major sections for readability:

```zortex
# Section 1
Content here.

# Section 2
More content.
```
