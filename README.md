<h1 align="center"> ✨ All-in-one personal management system for (Neo)vim ✨ </h1>

### What is this?
This is mean to be a second brain. An all-in-one personal management system. The goal is to allow one to store notes, todo lists, schedules, thoughts, etc. in a single location. It includes:
- A derivative of markdown which you can visualize in the browser, which utilizes [Markdown It](https://github.com/markdown-it/markdown-it).
- Useful functions and shortcuts for managing information in the markdown files.
- Fast file searching through a simple and predictable plain-text format. Currently I have 300 pages, at 38,000 lines, and can still immediately find what I need.

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
    - Changed variables from "g:mkdp_*" to "g:zortex_*"

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

