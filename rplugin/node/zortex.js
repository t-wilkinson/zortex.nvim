const fs = require('fs')
const readline = require('readline')
const open = require('open')
const path = require('path')
const cheerio = require('cheerio')
const fetch = require('node-fetch')
const os = require('os')
const process = require('process')

function readLines(filename) {
  const fileStream = fs.createReadStream(filename)
  const lines = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity,
  })
  return lines
}

async function readZortexLines(nvim, filePath) {
  const notesDir = await nvim.commandOutput(`echo g:zortex_notes_dir`)
  return readLines(path.join(notesDir, filePath))
}

async function getFirstLine(pathToFile) {
  const readable = fs.createReadStream(pathToFile)
  const reader = readline.createInterface({ input: readable })
  const line = await new Promise((resolve) => {
    reader.on('line', (line) => {
      reader.close()
      resolve(line)
    })
  })
  readable.close()
  return line
}

function normalizeArticleName(name) {
  return name.trim().toLowerCase().replace(/\s+/g, '-').replace(/^@+/, '')
}

function articleNamesMatch(n1, n2) {
  return normalizeArticleName(n1) === normalizeArticleName(n2)
}

const articleNameRE = /^@@/
async function getArticleNames(pathToArticle) {
  const names = []
  const lines = readLines(pathToArticle)
  for await (const line of lines) {
    if (articleNameRE.test(line)) {
      names.push(line)
      continue
    }
    break
  }

  return names
}

async function getArticlePath(nvim, articleName) {
  // find article matching link name and edit it
  const notesDir = await nvim.commandOutput(`echo get(g:, "zortex_notes_dir", 0)`)
  for await (const file of fs.readdirSync(notesDir)) {
    const articlePath = path.join(notesDir, file)
    const names = await getArticleNames(articlePath)

    for (const name of names) {
      nvim.command(`let @a="${articleName} ${name} ${articleNamesMatch(articleName, name)}"`)
      if (articleNamesMatch(articleName, name)) {
        return articlePath
      }
    }
  }
}

async function openArticle(nvim, articleName) {
  const filePath = await getArticlePath(nvim, articleName)

  if (filePath) {
    nvim.command(`edit ${filePath}`)
    return true
  } else {
    return false
  }
}

/*
 * check if project is nested in another project
 * @returns {string} nested project name
 */
async function findParentProjectName(nvim) {
  const pos = await nvim.commandOutput(`echo getpos(".")[1]`)
  const indent = Number(await nvim.commandOutput(`echo indent(${pos})`))

  // search backwards for parent project
  for (let currentPos = pos; currentPos > 0; currentPos--) {
    // looking for parent line
    const currentIndent = Number(
      await nvim.commandOutput(`echo indent(${currentPos})`)
    )
    if (currentIndent >= indent) {
      continue
    }

    const line = await nvim.commandOutput(`echo getline(${currentPos})`)

    // skip line if it is empty
    if (line === '') {
      continue
    }

    const match = line.match(projectRE)
    if (!match) {
      break
    }

    const parentProjectName = match[3]
    return parentProjectName
  }

  return null
}

/**
 * Find lineNumber of project in projects file
 *
 * @returns {number} line number of project in projects file
 */
async function findProjectLineNumber(
  nvim,
  projectName,
  startLineNumber = 1,
  indent = 0
) {
  const notesDir = await nvim.commandOutput(`echo g:zortex_notes_dir`)
  let lineNumber = 0

  const spaceRE = /\S|$/
  const lines = readLines(path.join(notesDir, 'projects.zortex'))
  for await (const line of lines) {
    lineNumber++

    if (lineNumber < startLineNumber) {
      continue
    }

    if (line === '') {
      continue
    }

    const currentIndent = line.search(spaceRE)
    // skip nested lines
    if (currentIndent > indent) {
      continue
    }

    // we are now outside of the project
    if (currentIndent < indent) {
      return null
    }

    const match = line.match(projectRE)
    if (!match) {
      continue
    }
    if (articleNamesMatch(projectName, match[3])) {
      return lineNumber
    }
  }
}

async function openProject(nvim, projectName) {
  const notesDir = await nvim.commandOutput(`echo g:zortex_notes_dir`)
  const projectsFile = path.join(notesDir, 'projects.zortex')
  let startLineNumber = 1
  let indentsize = 0
  let parentProjectName, parentLineNumber

  // find starting line of parent project
  const currentIndent = Number(
    await nvim.commandOutput(`echo indent(line("."))`)
  )
  if (currentIndent > 0) {
    parentProjectName = await findParentProjectName(nvim)
    if (parentProjectName) {
      parentLineNumber = await findProjectLineNumber(nvim, parentProjectName)
      if (parentLineNumber) {
        indentsize = await nvim.commandOutput(`echo &tabstop`)
        startLineNumber = parentLineNumber + 1
      }
    }
  }

  // set search register to project name to search for matching tags
  const normalizedName = normalizeArticleName(projectName)
    .replace(/\s+/g, '-')
    .replace(/\\/g, '\\\\')
    .replace(/\//g, '\\/')
  const searchTerm = `#${normalizedName}#\|^\s*- ${projectName}`
  nvim.command(`let @/ = '${searchTerm}'`)

  // goto line of project
  const lineNumber = await findProjectLineNumber(
    nvim,
    projectName,
    startLineNumber,
    indentsize
  )
  if (lineNumber) {
    await nvim.command(`edit +${lineNumber} ${projectsFile}`)
  } else if (parentProjectName && parentLineNumber) {
    await nvim.command(`edit +${parentLineNumber} ${projectsFile}`)
  } else {
    await nvim.command(`edit +/${searchTerm} ${projectsFile}`)
  }
  // await nvim.input('n')
}

async function openStructure(nvim, lines, structureName, indent) {
  const cursorLineNumber = await nvim.commandOutput(`echo line(".")`)
  let lineNumber = 0
  let articleName = null

  for await (const line of lines) {
    lineNumber++

    if (lineNumber > cursorLineNumber) {
      break
    }

    if (line === '') {
      continue
    }

    const currentIndent = line.search(/\S|$/)
    if (currentIndent >= indent) {
      continue
    }
    const match = line.match(articleLinkRE)
    if (!match) {
      continue
    }
    articleName = match[1]
  }

  if (!articleName) {
    return
  }

  const filePath = await getArticlePath(nvim, articleName)
  lineNumber = 0
  for await (const line of readLines(filePath)) {
    lineNumber++

    const match = line.match(zettelRE)
    if (!match) {
      continue
    }

    if (articleNamesMatch(match[3], structureName)) {
      await nvim.command(`edit ${filePath}`)
      await nvim.command(`normal! ${lineNumber}G`)
      return true
    }
  }
}

// const markdownLinkRE = /\[([^\]]+)\]\(([^\)]+)\)/
const lineRE = /^(\s*)- (.*)$/
const zettelRE = /^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(?<text>.*)$/
const projectRE = /^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(.*)$/
const zortexLineRE = /- (?<tags>#.+# )?(?<text>.*)$/

const websiteLinkRE = /https?:\/\/[^);}]+/
const fileLinkRE = /\[([^\]]+)\]\(([^\)]+)\)/
const fragmentLinkRE = /\|([^|]+)\|/
const zortexLinkRE = /ref=([^\s;}]+)/
const articleLinkRE = /\[([^\]]+)\]/
const filePathRE = /(^|\s)(?<path>[~.]?\/[/\S]+)($|\s)/
const linkRE = /\[(?<text>[^\]]+)\](\((?<ref>[^\)]+)\))?/
const headingRE = /^#+ (.*)$/

async function extractLink(nvim, line) {
  let match

  if ((match = line.match(websiteLinkRE))) {
    return {
      line,
      type: 'website',
      url: match[0],
    }
  } else if ((match = line.match(fileLinkRE))) {
    return {
      line,
      type: 'file',
      name: match[1],
      url: match[2],
    }
  } else if ((match = line.match(fragmentLinkRE))) {
    // get line from cursor to end of line
    let col = Number(await nvim.commandOutput(`echo getpos(".")[2]`))
    const re = new RegExp(fragmentLinkRE)

    while ((match = re.exec(line)) != null) {
      // find first match that the cursor is on or before
      // random |link| |link<cursor>| more |link| random text
      //        ^no match ^match            ^no match
      const link = match[1]
      if (col <= link.length + match.index) {

        return {
          line,
          type: 'fragment-link',
          fragment: link,
        }
      }
    }

  } else if ((match = line.match(zortexLinkRE))) {
    return {
      line,
      type: 'zortex-link',
      url: match[1],
    }
  } else if ((match = line.match(articleLinkRE))) {
    return {
      line,
      type: 'article',
      name: match[1],
    }
  } else if ((match = line.match(filePathRE))) {
    return {
      line,
      type: 'path',
      path: match[2],
    }
  } else if ((match = line.match(lineRE))) {
    return {
      line,
      type: 'text',
      indent: match[1].length,
      name: match[2],
    }
  } else if ((match = line.match(headingRE))) {
    return {
      line,
      type: 'heading',
      name: match[1],
    }
  } else {
    // get text under visual selection
    const selection = await nvim.commandOutput(
      `echo getline("'<")[getpos("'<")[2]-1:getpos("'>")[2]-1]`
    )

    return null
    // return {
    //   line,
    //   type: 'wikipedia',
    //   name: selection.trim(),
    // }
  }
}

async function openLink(nvim) {
  const line = await nvim.getLine()
  const filename = await nvim.commandOutput(`echo expand("%:t:r")`)

  // get article name
  const link = await extractLink(nvim, line)

  if (!link) {
    return null
  }

  if (link.url?.startsWith('./')) {
    link.url = path.join(await nvim.getVar('zortex_notes_dir'), link.url)
  }
  // nvim.command(`let @a='${Math.floor(Math.random() * 1000)}${filename}${JSON.stringify(link)}'`)

  if (filename === 'zortex-structures' && link.type === 'text') {
    const lines = await nvim.buffer.lines
    openStructure(nvim, lines, link.name, link.indent)
  } else if (filename === 'structure' && link.type === 'text') {
    const lines = await readZortexLines(nvim, 'structure.zortex')
    const opened = await openStructure(nvim, lines, link.name, link.indent)
    if (!opened) {
      open(`https://en.wikipedia.org/wiki/Special:Search/${link.name}`)
    }
  } else if (filename === 'schedule' && link.type === 'text') {
    openProject(nvim, link.name)
  } else if (link.type === 'wikipedia' || link.type === 'text') {
    if (link.name) {
      open(`https://en.wikipedia.org/wiki/Special:Search/${link.name}`)
    }
  } else if (link.type === 'path') {
    if (fs.lstatSync(link.path.replace(/^~/, os.homedir()))?.isDirectory()) {
      nvim.command(`edit ${link.path}`)
    } else {
      nvim.command(`edit ${link.path}`)
    }
  } else if (link.type === 'fragment-link') {
    // // move cursor forward one line to skip any matches of current line
    // let pos = await nvim.commandOutput(`echo getpos(".")[1]]`)
    // pos += 1
    // nvim.command(`call cursor(${pos}, 1)`)

    nvim.command(`call search('\\c\s*- ${link.fragment}', 'sw')`)
  } else if (link.type === 'zortex-link') {
    open(link.url)
  } else if (link.type === 'website' || link.type === 'resource' || link.type === 'file') {
    open(link.url)
  } else if (link.type === 'article') {
    openArticle(nvim, link.name)
  } else if (link.type === 'heading') {
    openArticle(nvim, link.name)
  }
}

function toZortexLink(info, tags=null) {
  function addParam(name, value) {
    if (value) {
      return `${name}=${value}`
    }
    return null
  }

  const params = Object.entries(info).map(([name, value]) => addParam(name, value)).filter(v => v).join('; ')
  return `${tags ? tags + ' ': ''}{${params}}`
}

async function getZortexLink(url) {
  // Get title from <h1> tag
  const respose = await fetch(url)
  const body = await respose.text()
  let $ = cheerio.load(body)
  let title = $('h1').text() || $('title').text()
  if (!title) {
    return null
  }
  title = title.replace(/\s+/g, ' ').trim()

  return {
    title,
    ref: url,
  }
}

function parseLinkText(text) {
  const subtitleIndex = text.indexOf(": ")
  const authorsIndex = text.indexOf(" - ", subtitleIndex || 0)

  let title = null
  let subtitle = null
  let authors = null

  if (subtitleIndex > 0 && authorsIndex > 0) {
    title = text.substring(0, subtitleIndex)
    subtitle = text.substring(subtitleIndex + 2, authorsIndex)
    authors = text.substring(authorsIndex + 3)
  } else if (subtitleIndex > 0) {
    title = text.substring(0, subtitleIndex)
    subtitle = text.substring(subtitleIndex + 2)
  } else if (authorsIndex > 0) {
    title = text.substring(0, authorsIndex)
    authors = text.substring(authorsIndex + 3)
  } else {
    title = text
  }

  return {
    title,
    subtitle,
    authors
  }
}

async function getLink(nvim, line) {
  let match

  function toLine(match, link) {
    const beforeLink = match.input.substring(0, match.index)
    const afterLink = match.input.substring(match.index + match[0].length)
    const line = `${beforeLink}${link}${afterLink}`
    return line
  }

  // try getting link from current line
  if (match = line.match(linkRE)) {
    const g = match.groups
    let ref = g.ref
    let { title, subtitle, authors } = parseLinkText(g.text)

    if (!title && g.ref || websiteLinkRE.test(title)) {
      let res = await getZortexLink(title)
      if (res) {
        ref = res.ref

        res = parseLinkText(res.title)
        title = res.title
        subtitle = res.subtitle
        authors = res.authors
      }
    }

    const link = toZortexLink({
      title,
      subtitle,
      authors,
      ref,
    })
    return toLine(match, link)

  } else if (match = line.match(websiteLinkRE)) {
    const link = toZortexLink(await getZortexLink(match[0]))
    return toLine(match, link)

  } else if (match = line.match(zortexLineRE)) {
    const g = match.groups
    const link = toZortexLink({
      title: g.text,
    })
    return toLine(match, `- ${g.tags}${link}`)
  }

  return null
}

async function createLink(nvim, args) {
  const [startLine, endLine] = args

  await Promise.all(new Array(endLine - startLine + 1).fill(0).forEach((_, i) =>
    nvim.commandOutput(`echo getline(${startLine + i})`)
    .then(line => getLink(nvim, line))
    .then(async (link) => {
      nvim.command(`undojoin`)
      return link
    })
    .then(link => link && nvim.command(`call setline(${startLine+i}, '${link.replace(/'/g, "''")}')`))
  ))

  nvim.command(`write`)
}

module.exports = (plugin) => {
  const nvim = plugin.nvim
  plugin.setOptions({
    dev: true,
    alwaysInit: true,
  })

  plugin.registerCommand('ZortexSearchGoogle', (args) => {
    open(`https://www.google.com/search?q=${args.join(' ')}`)
  }, {
    nargs: '*',
  })
  plugin.registerCommand('ZortexSearchWikipedia', (args) => {
    open(`https://en.wikipedia.org/wiki/Special:Search/${args.join(' ')}`)
  }, {
    nargs: '*',
  })
  plugin.registerCommand('ZortexCreateLink', (args) => createLink(nvim, args), {
    range: '',
  })
  plugin.registerCommand('ZortexOpenLink', () => openLink(nvim), {})

  // Needed to prevent errors from closing the rplugins connection
  process
    .on('unhandledRejection', (reason, p) => {
      // nvim.errWrite(`"${reason}"`)
      console.error(reason, 'Unhandled Rejection at Promise', p);
    })
    .on('uncaughtException', err => {
      // nvim.errWrite(`"${err.toString()}"`)
      console.error(err, 'Uncaught Exception thrown');
    });
}

module.exports.default = module.exports
