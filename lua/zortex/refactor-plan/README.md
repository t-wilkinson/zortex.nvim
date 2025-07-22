# Zortex - A Gamified Personal Knowledge & Task Management System for Neovim

## Overview

Zortex is a comprehensive personal productivity system built as a Neovim plugin that combines task management, note-taking, project tracking, and knowledge organization with gamification elements. It uses a custom markup format (`.zortex` files) to create an interconnected system where completing tasks earns experience points, projects track progress automatically, and your knowledge base grows organically.

Think of it as a fusion of:

- **GTD (Getting Things Done)** methodology with areas, projects, and tasks
- **OKR (Objectives and Key Results)** for goal setting and tracking
- **Zettelkasten** for knowledge management with bidirectional links
- **RPG elements** with XP, levels, and skill trees for motivation

## Core Concepts

### 1. **Hierarchical Organization**

- **Areas**: High-level life domains (e.g., "Work/Engineering", "Personal/Health")
- **Projects**: Concrete initiatives with defined outcomes
- **Tasks**: Actionable items that can be completed
- **Objectives**: Time-bound goals with measurable key results

### 2. **Custom Markup Language**

```zortex
@@Article Title
@tag1

# Project Name @done(2024-01-20) @progress(5/10)
Links: [Areas/Work/Engineering]

## Subproject

- [ ] Task description @id(abc123) @due(2024-02-01) @p1
- [x] Completed task @done(2024-01-15)

**Bold Heading**:
Content under bold heading

Label:
Content with label formatting
```

### 3. **Experience & Progression System**

- Tasks award XP based on size, priority, and time horizon
- Areas accumulate XP and level up independently
- Seasonal progression with battle pass-style tiers
- Skill tree visualization of your expertise

## Key Features

### 📋 Task Management

- **Smart Task Tracking**: Automatic ID generation and state persistence
- **Rich Attributes**: Priority levels, due dates, time estimates, dependencies
- **Progress Tracking**: Visual progress indicators at project and objective levels
- **Bulk Operations**: Archive completed projects, update all progress at once
- **Task States**: Multiple states beyond done/not done (in progress, cancelled, delegated, unclear)

### 📁 Project Organization

- **Hierarchical Structure**: Unlimited nesting with heading levels
- **Automatic Progress**: Calculates completion based on subtasks
- **Project Attributes**: Size estimation, importance/priority ratings
- **Archive System**: Completed projects move to archive while preserving structure

### 🎯 OKR Integration

- **Time Horizons**: Daily, Monthly, Quarterly, Yearly, and multi-year objectives
- **Key Result Tracking**: Link key results to specific projects
- **Automatic Completion**: Objectives complete when all linked projects finish
- **Progress Visualization**: See completion rates by time span

### 🏔️ Areas (Life Domains)

- **Hierarchical Tree**: Organize areas in parent/child relationships
- **XP Accumulation**: Areas gain XP from related tasks and objectives
- **Bubble-up XP**: Child areas contribute XP to parent areas
- **Long-term Mastery**: Track expertise development over months/years

### 📅 Calendar System

- **Unified View**: See tasks, events, and notes in one place
- **Rich Entry Types**: Events with duration, repeating items, date ranges
- **iCal Integration**: Import/export calendar data
- **Time Blocking**: Schedule tasks with specific times and durations
- **Smart Notifications**: Get reminders for upcoming items

### 🔗 Knowledge Management

- **Bidirectional Links**: Connect any piece of information
- **Multi-format Links**: Support for internal links, URLs, file paths, footnotes
- **Context-aware Search**: Search within sections, articles, or globally
- **Smart Completion**: Intelligent link completion based on context
- **Breadcrumb Navigation**: Always know where you are in the hierarchy

### 🎮 Gamification & Motivation

- **XP System**: Earn experience for completing tasks and objectives
- **Level Progression**: Areas level up based on accumulated XP
- **Seasonal Challenges**: Time-bound progression with tier rewards
- **Skill Tree**: Visualize your expertise across different areas
- **Achievement Tracking**: See your progress over time

### 🔔 Notification System

- **Multi-provider Support**: System notifications, email, push notifications
- **Pomodoro Timer**: Built-in work/break cycle management
- **Custom Timers**: Set reminders for any duration
- **Calendar Sync**: Get notified about upcoming events
- **Daily Digest**: Email summary of tasks and events

### 🎨 Rich UI Components

- **Calendar View**: Interactive calendar with emoji indicators
- **Search Interface**: Telescope-based search with preview
- **Skill Tree Display**: Visual representation of area expertise
- **Progress Bars**: ASCII progress indicators throughout
- **Syntax Highlighting**: Custom highlighting with concealment

## File Structure

### Special Files

- `projects.zortex` - Active projects and tasks
- `areas.zortex` - Area hierarchy definition
- `okr.zortex` - Objectives and key results
- `calendar.zortex` - Calendar entries and events
- `z/archive.projects.zortex` - Archived projects
- `.z/` - System data (state files, logs)

### Markup Elements

- `@@Title` - Article/document title
- `@tag` - Tags for categorization
- `# Heading` - Hierarchical sections (up to 6 levels)
- `**Bold**:` - Bold headings (alternative to # syntax)
- `Label:` - Label sections
- `- [ ] Task` - Task with checkbox
- `[Link]` - Internal link
- `@attr(value)` - Attributes for tasks/projects

## Technical Architecture

### Modular Design

- **Core**: Parser, filesystem, datetime, buffer operations
- **Features**: Calendar, links, highlights, completion
- **Models**: Task and calendar entry objects
- **Modules**: Business logic for areas, projects, tasks
- **Stores**: Data persistence layer
- **UI**: User interface components
- **XP**: Gamification subsystem
- **Notifications**: Pluggable notification providers

### Key Differentiators

1. **Unified System**: Everything interconnected rather than separate tools
2. **File-based**: All data in plain text for version control and longevity
3. **Keyboard-driven**: Optimized for Vim workflows
4. **Progressive Disclosure**: Simple to start, powerful when needed
5. **Motivational**: Gamification that respects your time and goals

## Use Cases

- **Software Engineers**: Track projects, learn new technologies, manage technical debt
- **Students**: Organize coursework, track learning progress, manage deadlines
- **Freelancers**: Project management, time tracking, client organization
- **Researchers**: Knowledge management, literature notes, experiment tracking
- **Personal Development**: Habit tracking, goal setting, life management

## Philosophy

Zortex is built on the belief that:

- Your productivity system should motivate, not overwhelm
- Progress should be visible and celebrated
- Knowledge compounds when properly connected
- Tools should adapt to your workflow, not vice versa
- Gamification can make mundane tasks engaging without being manipulative

The plugin aims to be a "second brain" that not only stores information but actively helps you develop expertise and achieve your goals through intelligent tracking and motivational mechanics.
