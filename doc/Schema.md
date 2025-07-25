# Schema

## Links

Think of links as a reference to a section(s). Link paths refer to a sectional area of a file, and the subsequent part looks in that area for its section.

We have three scopes for links:
[Article name] or [Alias] -- We find the article with the line "@@Article name" or "@@Alias". There may be multiple articles with the same name so populate the quickfix.
[...] -- We have global link which searches all articles matching link.
[/...] -- We have local link which only looks at the current buffer.

We have different types of searches/sections:
[@Tag] -- Any file containing a line "@Tag"
[#Heading] -- Will find the line starting with "# Heading"
[:Label] -- A line starting with "Label:"; It can have text after the label
[*Highlight] -- Any text matching `*Highlight*`, `**Highlight**`, or `***Highlight***`, or `^**Highlight**:$` and `^**Highlight:**$` (the last two are considered a bold heading)
[-List] -- Any text matching `^\s*- `
[%Query] -- Any text matching the Query

Nesting:
For all scopes, we can nest searches for increasingly "specific" links by separating them with a forward slash. For example, [/#Heading/#Sub heading/#Sub sub heading], [#Heading/:Label] or even [Article name/@Tag/#Heading/:Label/%Query]

- Headings > Bold heading > Labels > List,Italic/Bold,Text
- Headings create a "section" until the next heading its level or higher.
- Bold headings of the format "^**<any text>**:\?$" create a "section" until the next heading or bold heading
- Labels create a "section" until the next heading, bold heading, or empty line
- Lists, italic/bold, and text are the smallest units

So in the first example...

```
[/#Heading/#Sub heading/#Sub sub heading] goes to...

# Heading
## Sub heading
### Another heading
#### Sub sub heading <- this line
```

This `[Article name/#Heading 1/:My Label/-Four]` links to...

```zortex
@@Article name

## Heading 1
Some text

My Label:
- One
- Two
- Three <- here
- Four
```

## Arcticle example

Files have 1 or more article names starting with "@@". Following, they have 0 or more tags starting with "@". Following, they have empty lines, paragraphs, headings, highlighted text, labels, etc.

```
@@Article name
@@Optional alias
@Optional Tag1
@Optional Tag2

# Heading 1
Label no text:
Label: with text following
- List
- like
    - markdown

## Sub heading
*Italics*
**Bold**
```

## Sections

Articles: first couple of lines of each file with the lines that start by "@@"

Headings: lines that start with 1-6 # followed by a space and text

Bold headings: lines that match the pattern "^\*\*._\*\*:$" or "^\*\*._:\*\*$"

Labels: lines that match "^my text:$" and the text cannot contain a sentence period (a period followed by a space ". ").

Each of these create a section. Each section gets priority in choosing when their section begins, ending previous sections up to their tier, creating a new section that contains all the tiers below them until a section of equal or higher precedence occurs in the file. So, labels create a new section, but a bold heading will end the label's section and create a new one. A level-3 heading will end all level-3 through 6 headings, bold headings, and labels when it occurs, containing all level-4 through 6 headings, bold headings, and labels.
