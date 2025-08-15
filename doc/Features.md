# Zortex Features

## Search

- Should show sections in order they appear in the file? Or use more complex sorting?

- Instead of document cache use a file modification-based cache
- DocumentManager/Sections should not treat code inside code blocks in the section hierarchy.

- Searching relies on DocumentManager.get_all_documents
- Do we really want to cache all documents?
- DocumentManager has a limited cache size right?
- Allow DocumentManager to hold multiple article names
- Operations like task management should be an extension of the normal operations
- Should we extend sections/documentmanager to include tasks for projects.zortex file, otherwise ignore? Otherwise it should not track tasks.

The search for "1 a" should show results for ...

```zortex
@@Article <- here

# 1 <- here
A label: <- here 
B label: <- not here

## apple <- here 
Label 1: <- here (it is a label within the apple heading)
### Breakfast <- here (this is a heading within 1 > a with 2 search tokens, so we show up to the level-3 headings)
Label 2: <- not here because the label is not directly under the extent of our search (## apple) here

## C <- not here
### amazing <- here 

# 2 <- not here
## Apple <- not here
## 1
another label: <- here
### another <- here
```

Article > 1 > A
Article > 1 > apple
Article > 1 > apple > Label 1
Article > 1 > apple > Breakfast
Article > 1 > apple > Breakfase
Article > 1 > C > amazing
Article > 2 > 1 > another label
Article > 2 > 1 > another

## Skill trees

completion_rate = data.task_count > 0 and (data.completed_tasks / data.task_count) or 0,
"[Test]"
Areas: Objectives in areas.zortex will list area links via "[A/...]" or "[Areas/...]" in a space separated list immediately below its heading. The link will include the full path via heading/label parts (for example "[A/#1 Personal Foundation/#1.1 Physical Health/:Cardiovascular Fitness]" or "[Areas/#1 Personal Foundation/#1.3 Spiritual & Core Values]"). Use links.lua or helpers/utils file to correctly parse and interpret the link location.

- cache areas.zortex tree in memory so we don't have to keep on parsing it. The file should stay relatively static, just its content will change.
- The XP from each area should distribute among a curve, with a parameter configurable by the user in the config.
- The areas skill-tree consists of first and second-level headings ("#" and "##") and labels (lines matching "^\w[^:.]\*:$")
- The key results should give some XP on a curve of a portion of the total XP of an objective.
- Objectives and key results should not give any XP in the base XP system, only the skill-tree system. Projects and tasks do not give any skill-tree XP. The XP system represents the total stuff I've done. The skill-tree system represents focused progress in different areas in my life. Make sure to update the system accordingly.
- Objectives give increasingly XP based on the length of its span code. The range of XP from M to 10Y should be large, on a gradual exponential curve.
- Skill XP should bubble up the tree to the root, increasing at each step by multiplying a parameter larger than 1.
- Provide a popup buffer to show skill tree and levels

An example areas.zortex:
```zortex # 1 Personal Foundation

    ## 1.1 Physical Health
    Cardiovascular Fitness:
        * Running
        * Cycling
        * Swimming

    Strength & Mobility:
        * Calisthenics Progressions
            - Push
            - Pull
            - Legs
        * Weightlifting Programs
        * Flexibility / Yoga

    Nutrition & Diet:
        * Macro Tracking
        * Meal Planning
        * Supplement Protocols

    ## 1.2 Spiritual & Core Values
    * Reflection & Journaling
    * Community / Faith Practices
    * Value Alignment Reviews

    # 2 Career & Professional Growth

    ## 2.1 Current Role

    * OKRs / KPIs
    * Team Leadership
    * Project Roadmaps

    ## 2.2 Skill Development
    Technical:
        * Programming Languages (Rust, JS)
        * DevOps / Cloud (NixOS, AWS)
    ```

Example okr.zortex:
```zortex # Current Objectives

    ## Y 2025 01 Become proficient in systems programming
    [A/#2 Career & Professional Growth/#2.2 Skill Development/:Technical]
    - KR-1: Complete [Learn Rust] project
    - KR-2: Build a [memory allocator] in C

    # Previous Objectives @progress(3/3) @done(2025-07-08)

    ## Q 2024 10 Improve development workflow @done(2024-12-20)
    [A/#2 Career & Professional Growth/#2.2 Skill Development] [Areas/#1 Personal Foundation/#1.4 Self Development]
    - KR-1: Set up [Neovim IDE] with LSP
    - KR-2: Create [Zortex system] for notes
    ```
