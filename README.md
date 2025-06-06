<h1 align="center"> ✨ All-in-one personal management system for (Neo)vim ✨ </h1>

### What is this?

This is mean to be a second brain. An all-in-one personal management system. The goal is to allow one to store notes, todo lists, schedules, thoughts, etc. in a single location. It includes:

- A derivative of markdown which you can visualize in the browser, which utilizes [Markdown It](https://github.com/markdown-it/markdown-it).
- Useful functions and shortcuts for managing information in the markdown files.
- Fast file searching through a simple and predictable plain-text format. Currently I have 300 pages, at 38,000 lines, and can still immediately find what I need.

### Purpose

Originally I had set to replicate the zettelkasten technique more closely, where each line was a different thought with a unique id and various tags. You could then query thoughts with certain tags. Although conceptually very interesting, I didn't actually find it useful. It allowed a purely flat layout of all my thoughts. However it had a few flaws:

- It was complicated.
- I was never encouraged to actually think and integrate my thoughts into something more meaningful as I would rely on the tag system to organize my notes.
- It discouraged thinking deeply about concepts.
- By design, it lacks a single source of truth for concepts. I'm limited

I found this new system better:

- Have a couple _core_ files:
  - **Structure:** is the most importantt. It is a single file that links to all my other notes. Using vim's folding, You can get an overview of the main domains of your wikipedia, or dive down. You can put the same article in multiple locations. This allows you to continue a graph-like knowledge base, while attaching a lot of information, depth, and thought into each thought.
  - **Storage:** this is a collection of all my old files/thoughts that it will not search through. Good for stuff I will probably never need again, but keep there just in case.
  - **Resources:**
  - **Schedule:**
  - **Projects:**
  - **Inbox:** a file that somewhat matches the original zettelkasten. Each 'unique' id is the line number. You can add tags to each line.
- Prefix lines with tags such as `- #one#two# This is my line text.` Provides a natural, intuitive way to organize thoughts that can still be easily searched. Provides a natural, intuitive way to organize thoughts that can still be easily searched.
- To still express the graph knowledge that the zettelkasten provides, I've found a hybrid approach of within your articles, add subheadings that refer to or connect ideas to other articles. Which is exactly what wikipedia does.

However this is not how I think. Overtime, I found my usecase of a note system closely mirrored a personal wikipedia. I would have 10s-100s of articles that I could quickly search.

### Where did the name come from?

- Zettelkasten (german for note "zettel" desk "kasten") was a note taking system popularized by Niklas Luhmann, a very prolific sociologist.
- Cortex, latin for bark. Its found in the word "neocortex" and "cerebral cortex". The neocortex is a key component in cognition. The Zortex is meant to be a sort of second brain.

### Required programs

- rsync: transfer local wiki to remote server through SSH
- bat: preview files
- fd: sourcing files

### Code stolen from/inspired by

- https://github.com/iamcco/markdown-preview.nvim

  - Integrates with markdown-it and vim to preview markdown-type buffers in the browser
  - Converted class components to functional components
  - Changed variables from "g:mkdp*\*" to "g:zortex*\*"

- https://github.com/markdown-it/markdown-it

  - Provides wonderful markdown processing in the browser

- https://github.com/alok/notational-fzf-vim
  - Integrates with fzf to search note system

### Introduction

> It only works on vim >= 8.1 and neovim

Preview markdown on your modern browser with synchronised scrolling and flexible configuration

Main features:

- Cross platform (macos/linux/windows)
- Synchronised scrolling
- Fast asynchronous updates
- [Katex](https://github.com/Khan/KaTeX) for typesetting of math
- [Plantuml](https://github.com/plantuml/plantuml)
- [Mermaid](https://github.com/knsv/mermaid)
- [Chart.js](https://github.com/chartjs/Chart.js)
- [sequence-diagrams](https://github.com/bramp/js-sequence-diagrams)
- [flowchart](https://github.com/adrai/flowchart.js)
- [dot](https://github.com/mdaines/viz.js)
- [Toc](https://github.com/nagaozen/markdown-it-toc-done-right)
- Emoji
- Task lists
- Local images
- Flexible configuration

![screenshot](https://user-images.githubusercontent.com/5492542/47603494-28e90000-da1f-11e8-9079-30646e551e7a.gif)

### install & usage

```vim
" If you have node.js and yarn
Plug "t-wilkinson/zortex.nvim", { 'do': 'cd app && yarn install' }
```

### Zortex Config:

- Please take a look at `plugin/zortex.vim` for config defaults and documentation

Commands:

```vim
:ZortexSearch
:ZortexSearchUnique

:ZortexCopyZettelId
:ZortexCopyZettel
:ZortexBranchToOutline
:ZortexBranchToArticle
:ZortexListitemToZettel
:ZortexResourceToZettel
:ZortexOpenStructure

:ZortexStartServer " call this before preview
:ZortexStopServer
:ZortexPreview
:ZortexPreviewStop
:ZortexPreviewToggle
```

### Reference

- [coc.nvim](https://github.com/neoclide/coc.nvim)
- [@chemzqm/neovim](https://github.com/neoclide/neovim)
- [chart.js](https://github.com/chartjs/Chart.js)
- [highlight](https://github.com/highlightjs/highlight.js)
- [neovim/node-client](https://github.com/neovim/node-client)
- [next.js](https://github.com/zeit/next.js)
- [markdown.css](https://github.com/iamcco/markdown.css)
- [markdown-it](https://github.com/markdown-it/markdown-it)
- [markdown-it-katex](https://github.com/waylonflinn/markdown-it-katex)
- [markdown-it-plantuml](https://github.com/gmunguia/markdown-it-plantuml)
- [markdown-it-chart](https://github.com/tylingsoft/markdown-it-chart)
- [mermaid](https://github.com/knsv/mermaid)
- [opener](https://github.com/domenic/opener)
- [sequence-diagrams](https://github.com/bramp/js-sequence-diagrams)
- [socket.io](https://github.com/socketio/socket.io)

### Use case ideas

- I like to open a split browser in full screen next to my terminal window.

### TODOS

- Change the FZF title when searching so you don't see that super long shortened path.
- Convert original resource link to tag setup `[name]{author=...; ref=...}` -> `#author=...#[name](ref)`
- When searching files, initially populate each file with only the article names for quick searching. it is possible to do some form of multiprocessing

### Ideal searching behavior

- The left side of search should be either the modified or created article time and the article name.
- Each file should be named a unique article name.
- Searching should be plain text using rg or fzf. rg or fzf should get each article file path and return the name of each match and if possible the matching phrase.
- It might be better to do a custom searching window using a lazyvim plugin.

**Better file names:**
[] Write script to move the article name and remove the article name? We would be limited by os by file names. Also wouldn't ease code if we are still doing aliases.
