import * as readline from 'readline'
import * as path from 'path'
import * as fs from 'fs'

import strftime from 'strftime'
import { Articles, Zettels } from './types'
import { readLines } from './helpers'
import { fetchQuery, matchQuery } from './query'

export function newZettelId() {
  const randInt = (1e5 + Math.random() * 1e5 + '').slice(-5)
  return strftime(`z:%H%M.%u%U%g.${randInt}`)
}

export function toZettel(
  id: string,
  tags: string[],
  content: string | string[]
) {
  if (typeof content === 'string') {
    return `[${id}] #${tags.join('#')}# ${content}`
  } else {
    return `[${id}] #${tags.join('#')}# ${content.join('\n')}`
  }
}

function showZettel(id: string, tags: string[], content: string | string[]) {
  if (typeof content === 'string') {
    return `\x1b[33m[${id}] \x1b[36m#${tags.join('#')}# \x1b[0m${content}`
  } else {
    return `\x1b[33m[${id}] \x1b[36m#${tags.join('#')}# \x1b[0m${content.join(
      '\n'
    )}`
  }
}

export function showZettels(ids: string[], zettels: Zettels) {
  for (const id of ids) {
    const zettel = zettels.ids[id]
    console.log(showZettel(id, zettel.tags, zettel.content))
  }
}

export async function indexZettels(zettelsFile: string): Promise<Zettels> {
  let lineNumber = 0
  let id: string
  let tags: string[]
  let content: string
  let zettels: Zettels = {
    tags: {},
    ids: {},
  }
  const zettelRE = /^\[(z:[0-9.]*)]\s*(#.*#)?\s*(.*)$/
  const lines = readLines(zettelsFile)

  for await (const line of lines) {
    lineNumber++
    const match = line.match(zettelRE)
    if (!match) {
      // If there is no match, merge information with previous zettel
      if (id) {
        if (!Array.isArray(zettels.ids[id].content)) {
          zettels.ids[id].content = [zettels.ids[id].content as string]
        }
        ;(zettels.ids[id].content as string[]).push(line)
      }
      continue
    }

    if (zettels.tags[id]?.has('z-source')) {
      const content = zettels.ids[id].content
      if (typeof content === 'string') {
        zettels.ids[id].content = `[z-source]{${content}}`
      } else {
        zettels.ids[id].content = `[z-source]{${content.join('\n')}}`
      }
    }

    id = match[1]
    tags = match[2] ? match[2].replace(/^#|#$/g, '').split('#') : []
    content = match[3] || ''

    if (zettels.ids[id]) {
      throw new Error(
        `Zettel id: ${id} already exists at line: ${zettels.ids[id].lineNumber}`
      )
    }

    // Index tags for fast access
    for (const tag of tags) {
      if (!zettels.tags[tag]) {
        zettels.tags[tag] = new Set()
      }
      zettels.tags[tag].add(id)
    }

    // Index zettels for fast access
    zettels.ids[id] = {
      lineNumber,
      tags,
      content,
    }
  }

  return zettels
}

export async function populateHub(lines: readline.Interface | string[], zettels: Zettels) {
  let newLines = []
  newLines.push('[[toc]]')

  for await (const line of lines) {
    // If line is a query, fetch zettels and add them to the hub
    const queryMatch = matchQuery(line)
    if (!queryMatch) {
      newLines.push(line)
      continue
    }

    // Execute query
    const [indent, query] = queryMatch
    const results = fetchQuery(query, zettels)

    // Populate file with query responses
    const resultZettels = results.map((id) => zettels.ids[id])
    for (const zettel of resultZettels) {
      if (Array.isArray(zettel.content)) {
        newLines.push(`${' '.repeat(indent)}- ${zettel.content[0]}`)
        for (const line of zettel.content.slice(1)) {
          newLines.push(`${' '.repeat(indent)}${line}`)
        }
      } else {
        newLines.push(`${' '.repeat(indent)}- ${zettel.content}`)
      }
    }
  }

  return newLines
}

export async function indexCategories(categoriesFile: string) {
  const categoriesRE = /^\s*- ([^#]*) (#.*#)$/
  const lines = readLines(categoriesFile)
  let match: RegExpMatchArray
  let category: string
  let categories: string[]
  const graph: { [key: string]: Set<string> } = {}
  const sortedGraph: { [key: string]: string[] } = {}

  for await (const line of lines) {
    match = line.match(categoriesRE)
    if (!match) {
      continue
    }

    category = match[1]
    categories = match[2].replace(/^#|#$/g, '').split('#')
    if (graph[category]) {
      for (const c of categories) {
        graph[category].add(c)
      }
    } else {
      graph[category] = new Set(categories)
    }
  }

  // Sort categories
  for (const category in graph) {
    sortedGraph[category] = Array.from(graph[category]).sort()
  }

  return sortedGraph
}

const articleRE = /.zortex/
const tagRE = /^([A-Z][a-z]*)?(@+)(.*)$/
export async function indexArticles(projectDir: string) {
  let match: RegExpMatchArray
  const articles: Articles = { names: new Set(), tags: new Set(), ids: {} }

  await Promise.all(
    fs.readdirSync(projectDir).map(async (file) => {
      if (!articleRE.test(file)) {
        return
      }

      for await (const line of readLines(path.join(projectDir, file))) {
        match = line.match(tagRE)
        if (line.length === 0) {
          continue
        }
        if (!match) {
          return
        }

        if (!articles.ids[file]) {
          articles.ids[file] = { name: null, tags: [] }
        }

        if (match[2].length === 1) {
          articles.tags.add(match[3])
          articles.ids[file].tags.push(match[3])
        } else {
          articles.names.add(match[3])
          articles.ids[file].name = match[3]
        }
      }
    })
  )

  return articles
}
