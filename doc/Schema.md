We have three scopes of searching:
[Article name] or [Alias] -- We find the article with the line "@@Article name" or "@@Alias". There may be multiple articles with the same name so populate the quickfix.
[...] -- We have global link which searches all articles matching link.
[/...] -- We have local link which only looks at the current buffer.

We have different types of searches:
[@Tag] -- Any file containing a line "@Tag"
[#Heading] -- Will find the line starting with "# Heading"
[:Label] -- A line starting with "Label:"; It can have text after the label
[*Highlight] -- Any text matching *Highlight*, **Highlight**, or ***Highlight***
[%Query] -- Any text matching the Query

Nesting:
For all scopes, we can nest searches for increasingly "specific" links by separating them with a forward slash. For example, [/#Heading/##Sub heading/###Sub sub heading], [#Heading/:Label] or even [Article name/@Tag/#Heading/:Label/%Query]


Article example:
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

