import MarkdownIt from 'markdown-it'
import hljs from 'highlight.js' // TODO: hljs has a large bundle size
import emoji from 'markdown-it-emoji'
import taskLists from 'markdown-it-task-lists'
import footnote from 'markdown-it-footnote'
import markdownItAnchor from 'markdown-it-anchor'
import markdownItToc from 'markdown-it-toc-done-right'
import markdownDeflist from 'markdown-it-deflist'

import mk from './katex'
import chart from './chart'
import mkitMermaid from './mermaid'
import linenumbers from './linenumbers'
import image from './image'
import diagram from './diagram'
import flowchart from './flowchart'
import dot from './dot'
import blockUml from './blockPlantuml'
import codeUml from './plantuml'
import { meta } from './meta'
import markdownImSize from './markdown-it-imsize'
import mkZortex from './zortex'

const anchorSymbol =
  '<svg class="octicon octicon-link" viewBox="0 0 16 16" version="1.1" width="16" height="16" aria-hidden="true"><path fill-rule="evenodd" d="M4 9h1v1H4c-1.5 0-3-1.69-3-3.5S2.55 3 4 3h4c1.45 0 3 1.69 3 3.5 0 1.41-.91 2.72-2 3.25V8.59c.58-.45 1-1.27 1-2.09C10 5.22 8.98 4 8 4H4c-.98 0-2 1.22-2 2.5S3 9 4 9zm9-3h-1v1h1c1 0 2 1.22 2 2.5S13.98 12 13 12H9c-.98 0-2-1.22-2-2.5 0-.83.42-1.64 1-2.09V6.25c-1.09.53-2 1.84-2 3.25C6 11.31 7.55 13 9 13h4c1.45 0 3-1.69 3-3.5S14.5 6 13 6z"></path></svg>'


const DEFAULT_OPTIONS = {
  mkit: {
    // Enable HTML tags in source
    html: true,
    // Use '/' to close single tags (<br />).
    // This is only for full CommonMark compatibility.
    xhtmlOut: true,
    // Convert '\n' in paragraphs into <br>
    breaks: false,
    // CSS language prefix for fenced blocks. Can be
    // useful for external highlighters.
    langPrefix: 'language-',
    // Autoconvert URL-like text to links
    linkify: true,
    // Enable some language-neutral replacement + quotes beautification
    typographer: true,
    // Double + single quotes replacement pairs, when typographer enabled,
    // and smartquotes on. Could be either a String or an Array.
    //
    // For example, you can use '«»„“' for Russian, '„“‚‘' for German,
    // and ['«\xA0', '\xA0»', '‹\xA0', '\xA0›'] for French (including nbsp).
    quotes: '“”‘’',
    // Highlighter function. Should return escaped HTML,
    // or '' if the source string is not changed and should be escaped externally.
    // If result starts with <pre... internal wrapper is skipped.
    highlight: function (str, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return `<pre class="hljs"><code>${
            hljs.highlight(lang, str, true).value
          }</code></pre>`
        } catch (__) {}
      }

      return `<pre class="hljs"><code>${escape(str)}</code></pre>`
    },
  },
  katex: {
    throwOnError: false,
    errorColor: ' #cc0000',
  },
  uml: {},
  toc: {
    listType: 'ul',
  },
  zortex: {},
}

export default (options = {}) => {
  let md
  const {
    mkit = {},
    katex = {},
    uml = {},
    hide_yaml_meta: hideYamlMeta = 1,
    sequence_diagrams: sequenceDiagrams = {},
    flowchart_diagrams: flowchartDiagrams = {},
    toc = {},
    zortex = {},
  } = options

  // markdown-it
  md = new MarkdownIt({
    ...DEFAULT_OPTIONS.mkit,
    ...mkit,
  })
  if (hideYamlMeta === 1) {
    md.use(
      meta([
        ['---', '\\.\\.\\.'],
        ['---', '\\.\\.\\.'],
      ])
    )
  }
  // katex
  md
    .use(mk, {
      ...DEFAULT_OPTIONS.katex,
      ...katex,
    })
    .use(blockUml, {
      ...DEFAULT_OPTIONS.uml,
      ...uml,
    })
    .use(codeUml, {
      ...DEFAULT_OPTIONS.uml,
      ...uml,
    })
    .use(mkZortex, {
      ...DEFAULT_OPTIONS.zortex,
      ...zortex,
    })
    .use(emoji)
    .use(taskLists)
    .use(markdownDeflist)
    .use(footnote)
    .use(image)
    .use(markdownImSize)
    .use(linenumbers)
    .use(mkitMermaid)
    .use(chart.chartPlugin)
    .use(diagram, {
      ...sequenceDiagrams,
    })
    .use(flowchart, flowchartDiagrams)
    .use(dot)
    .use(markdownItAnchor, {
      permalink: true,
      permalinkBefore: true,
      permalinkSymbol: anchorSymbol,
      permalinkClass: 'anchor',
    })
    .use(markdownItToc, {
      ...DEFAULT_OPTIONS.toc,
      ...toc,
    })

  return md
}
