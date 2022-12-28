import { isSpace } from 'markdown-it/lib/common/utils'

function escapeRegExp(string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

const listitemRE = /^\s*([A-Za-z0-9]+)\.\s*$/
const timeRE = /^\s*(\d+:\d\d)\s*$/
function getListitem(state, startLine) {
  var pos, newline, line, listitem

  pos = state.bMarks[startLine] + state.tShift[startLine]
  newline = state.src.indexOf('\n', pos)
  line = state.src.slice(pos, newline)

  const match = line.match(listitemRE) || line.match(timeRE)
  if (!match) {
    return false
  }

  listitem = match[1]
  pos += match[0].length
  return { pos, listitem }
}

function markTightParagraphs(state, idx) {
  var i,
    l,
    level = state.level + 2

  for (i = idx + 2, l = state.tokens.length - 2; i < l; i++) {
    if (
      state.tokens[i].level === level &&
      state.tokens[i].type === 'paragraph_open'
    ) {
      state.tokens[i + 2].hidden = true
      state.tokens[i].hidden = true
      i += 2
    }
  }
}

function zettelListitem(state, startLine, endLine, silent) {
  var indent,
    listTokIdx,
    max,
    nextLine,
    offset,
    oldListIndent,
    oldSCount,
    oldTShift,
    oldTight,
    token,
    start,
    pos,
    listitem,
    tight = true

  start = state.bMarks[startLine] + state.tShift[startLine] + 1
  let res = getListitem(state, startLine)
  if (!res) {
    return false
  }
  pos = res.pos
  listitem = res.listitem

  // For validation mode we can terminate immediately
  if (silent) {
    return true
  }

  // Start list
  listTokIdx = state.tokens.length
  nextLine = startLine

  // Parse line and children
  max = state.eMarks[nextLine]
  indent = offset =
    state.sCount[nextLine] +
    start -
    (state.bMarks[startLine] + state.tShift[startLine])

  // Run subparser & write tokens
  token = state.push('zortex_listitem_open', 'div', 1)
  token.attrSet('class', 'z-listitem')
  token.map = [startLine, nextLine]

  token = state.push('inline', '', 0)
  token.content = `${listitem}.`
  token.map = [startLine, nextLine]
  token.children = []

  token = state.push('zortex_listitem_close', 'div', -1)

  // change current state, then restore it after parser subcall
  oldTight = state.tight
  oldTShift = state.tShift[startLine]
  oldSCount = state.sCount[startLine]

  //  - example list
  // ^ listIndent position will be here
  //   ^ blkIndent position will be here
  //
  oldListIndent = state.listIndent
  state.listIndent = state.blkIndent
  state.blkIndent = indent

  state.tight = true
  state.tShift[startLine] = pos - state.bMarks[startLine]
  state.sCount[startLine] = offset

  if (pos >= max && state.isEmpty(startLine + 1)) {
    // workaround for this case
    // (list item is empty, list terminates before "foo"):
    // ~~~~~~~~
    //   -
    //
    //     foo
    // ~~~~~~~~
    state.line = Math.min(state.line + 2, endLine)
  } else {
    state.md.block.tokenize(state, startLine, endLine, true)
  }

  // If any of list item is tight, mark list as tight
  if (!state.tight) {
    tight = false
  }

  state.blkIndent = state.listIndent
  state.listIndent = oldListIndent
  state.tShift[startLine] = oldTShift
  state.sCount[startLine] = oldSCount
  state.tight = oldTight

  // mark paragraphs tight if needed
  // if (tight) {
  //   markTightParagraphs(state, listTokIdx);
  // }

  return true
}

const tagRE = /^\w*(@+).+/
function zettelTag(state, startLine, _endLine, silent) {
  let token, pos, newline, tags
  pos = state.bMarks[startLine] + state.tShift[startLine]
  newline = state.src.indexOf('\n', pos)

  const line = state.src.slice(pos, newline)
  const match = line.match(tagRE)
  if (!match) {
    return false
  }
  tags = match[1]

  state.line = startLine + 1

  if (silent) {
    return true
  }

  token = state.push('zortex_tag_open', 'div', 1)
  token.markup = tags
  token.attrSet('class', 'z-tag')
  token.map = [startLine, state.line]

  token = state.push('inline', '', 0)
  token.content = line.trim()
  token.map = [startLine, state.line]
  token.children = []

  token = state.push('zortex_tag_close', 'div', -1)

  return true
}

const operators = [
  ':',
  ':=',
  '<->',
  '<-',
  '->',
  '~>',
  '<=>',
  '=>',
  '!=',
  '==',
  '+',
  'vs.',
  '|',
]
const operatorRE = new RegExp(
  `^(${operators.map((op) => escapeRegExp(op)).join('|')})`
)
const maxOperatorLength = operators.reduce(
  (max, op) => Math.max(max, op.length),
  0
)

function zettelLineTag(state, silent) {
  let token, pos, max, code
  pos = state.pos
  max = state.posMax

  if (state.src.charCodeAt(pos) !== 35 /* # */) {
    return false
  }

  for (; pos < max; pos++) {
    code = state.src.charCodeAt(pos)
    if (isSpace(code) || code === 0x3b || code === 0x7d) {
      break
    }
  }
  if (state.src.charCodeAt(pos - 1) !== 35 /* # */) {
    return false
  }

  if (silent) {
    return true
  }

  token = state.push('zortex_linetag_open', 'span', 1)
  token.attrs = [['class', 'z-operator']]

  token = state.push('text', '', 0)
  token.content = state.src.slice(state.pos, pos)

  token = state.push('zortex_linetag_close', 'span', -1)

  state.pos = pos
  return true
}

function zettelOperator(state, silent) {
  let operator, token, match

  // Get operator
  // ex: _==_ or _:_ or _:=_
  if (!isSpace(state.src.charCodeAt(state.pos - 1))) {
    return false
  }
  match = state.src
    .slice(state.pos, state.pos + maxOperatorLength)
    .match(operatorRE)
  if (!match) {
    return false
  }
  operator = match[1]
  if (!isSpace(state.src.charCodeAt(state.pos + operator.length))) {
    return false
  }

  if (silent) {
    return true
  }

  token = state.push('zortex_operator_open', 'span', 1)
  token.attrs = [['class', 'z-operator']]

  token = state.push('text', '', 0)
  token.content = operator

  token = state.push('zortex_operator_close', 'span', -1)

  state.pos = state.pos + operator.length
  return true
}

const sources = {
  image(state, attrs) {
    let token

    token = state.push('image', 'img', 0)
    token.attrs = attrs = [
      ['src', attrs.ref],
      ['alt', attrs.title],
    ]
    token.content = attrs.title
  },
  link(state, attrs) {
    let token

    token = state.push('link_open', 'a', 1)
    token.attrs = [
      ['target', '_blank'],
      ['href', attrs.ref],
      ['title', attrs.title],
    ]

    token = state.push('text', '', 0)
    token.content = attrs.title

    token = state.push('link_close', 'a', -1)
  },
  website() {},
}

/**
 * Process [z-source]{ key1=value1; key2=value2; key3=value3 }
 */
function zettelSource(state, silent) {
  let start,
    middle,
    end,
    labelStart,
    labelEnd,
    code,
    token,
    key,
    value,
    attrs = {},
    pos = state.pos,
    max = state.posMax

  if (state.src.charCodeAt(state.pos) !== 0x5b /* [ */) {
    return false
  }

  labelStart = state.pos + 1
  labelEnd = state.md.helpers.parseLinkLabel(state, state.pos, true)

  // parser failed to find ']', so it's not a valid link
  if (labelEnd < 0) {
    return false
  }

  if ('z-source' !== state.src.slice(labelStart, labelEnd)) {
    return false
  }

  pos = labelEnd + 1
  if (pos >= max || state.src.charCodeAt(pos) !== 0x7b /* { */) {
    return false
  }
  pos++

  //   [key]=[value];  }
  // ^^ skipping space
  for (; pos < max; pos++) {
    code = state.src.charCodeAt(pos)
    if (!isSpace(code) && code !== 0x0a) {
      break
    }
  }
  if (pos >= max) {
    return false
  }

  while (true) {
    start = pos

    //   [key]=[value];  }
    //   ^^^^^ alphanumericdash
    for (; pos < max; pos++) {
      if (state.src.charCodeAt(pos) === 0x3d) {
        break
      }
    }
    if (pos >= max) {
      return false
    }
    //   [key]=[value];  }
    //        ^ middle
    middle = pos

    //   [key]=[value];  }
    //                ^ semicolon
    pos++
    for (; pos < max; pos++) {
      code = state.src.charCodeAt(pos)
      if (isSpace(code) || code === 0x3b || code === 0x7d) {
        break
      }
    }
    if (pos >= max) {
      return false
    }
    end = pos
    key = state.src.slice(start, middle)
    value = state.src.slice(middle + 1, end)
    attrs[key] = value
    if (code === 0x7d) {
      pos++
      break
    }

    //   [key]=[value];  }
    //                 ^^ space
    pos++
    for (; pos < max; pos++) {
      code = state.src.charCodeAt(pos)
      if (!isSpace(code) && code !== 0x0a) {
        break
      }
    }
    if (pos >= max) {
      return false
    }

    //   [key]=[value];  }
    //                   ^ bracket
    if (state.src.charCodeAt(pos) === 0x7d) {
      pos++
      break
    }
  }

  if (silent) {
    return true
  }

  const source = sources[attrs.resource]
  if (source) {
    source(state, attrs)
  } else {
    token = state.push('text', '', 0)
    token.content = attrs.title
  }

  state.pos = pos
  state.posMax = max
  return true
}

function zettelBlock(state, startLine, _endLine, silent) {
  let pos, token, nextLine
  nextLine = startLine + 1
  pos = state.bMarks[startLine] + state.tShift[startLine]

  if (state.src.charCodeAt(pos) !== 0x5b /* [ */) {
    return false
  }

  if (silent) {
    return true
  }

  token = state.push('zortex_block', 'div', 1)
  token.attrs = [['class', 'z-block']]
  token.map = [startLine, nextLine]
  token.block = true

  token = state.push('inline', '', 0)
  token.content = state.src.slice(pos, state.eMarks[startLine])
  token.map = [startLine, nextLine]
  token.children = []

  token = state.push('zortex_block', 'div', -1)

  state.line = nextLine
  return true
}

function zettelTOC(state) {
  let i, token;
  let toc = []
  for (i = 0; i < state.tokens.length; i++) {
    token = state.tokens[i]
    if (token.type === 'list_item_open' && token.level <= 3) {
      i += 2
      toc.push(state.tokens[i])
    }
  }
  console.log(state)
  console.log(toc)
}

export default function zettelkasten(md) {
  md.block.ruler.before('paragraph', 'zortex_block', zettelBlock)
  md.block.ruler.before('paragraph', 'zortex_tag', zettelTag)
  md.block.ruler.before('paragraph', 'zortex_listitem', zettelListitem)
  md.inline.ruler.before('emphasis', 'zortex_operator', zettelOperator)
  md.inline.ruler.before('emphasis', 'zortex_operator', zettelLineTag)
  md.inline.ruler.before('link', 'zortex_source', zettelSource)
  // md.core.ruler.push('zortex_toc', zettelTOC)
}
