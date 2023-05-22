import * as path from 'path'
import * as fs from 'fs'

import strftime from 'strftime'
import {Articles, Zettels, Lines} from './types'
import {readLines} from './helpers'
import {isQuery, fetchQuery, parseQuery} from './query'

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
    console.log(showZettel(id, [...zettel.tags], zettel.content))
  }
}

export async function indexZettels(zettelsFile: string): Promise<Zettels> {
  let lineNumber = 0
  let id: string
  let tags: Set<string>
  let content: string | string[]
  const zettels: Zettels = {
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
        ; (zettels.ids[id].content as string[]).push(line)
      }
      continue
    }

    //     if (zettels.ids[id].tags?.has('z-source')) {
    //       const source = zettels.ids[id].content
    //       zettels.ids[id].content =
    //         typeof source === 'string'
    //           ? `[z-source]{${source}}`
    //           : `[z-source]{${source.join('\n')}}`
    //     }

    id = match[1]
    tags = new Set(match[2] ? match[2].replace(/^#|#$/g, '').split('#') : [])
    content = match[3] ? match[3] : []

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

const indentRE = /\S/
export async function populateHub(lines: Lines, zettels: Zettels, notesDir: string): Promise<string[]> {
  const newLines = []
  newLines.push('[[toc]]')

  let query
  let indent
  let queryResults
  let queryStructure

  for await (let line of lines) {
  // sub query structure should form nested dictionaries, descending matchings tags until no tag matches, then placing it there
      // Find the sub structure in the query and correctly populate it with search results
      // Find a way to convert tags to the right structure

    if (query) {
      // Check if query ends
      const indent = line.match(indentRE)?.index
      if (indent <= query.indent) {
        // Query ends, finally build the structure

        // Populate file with query responses
        const resultZettels = queryResults.map((id) => zettels.ids[id])
        for (const zettel of resultZettels) {
          if (Array.isArray(zettel.content)) {
            newLines.push(`${' '.repeat(query.indent)}- ${zettel.content[0]}`)
            for (const line of zettel.content.slice(1)) {
              newLines.push(`${' '.repeat(query.indent)}${line}`)
            }
          } else {
            newLines.push(`${' '.repeat(query.indent)}- ${zettel.content}`)
          }
        }

        query = null
        queryResults = null
        queryStructure = null
      } else {
        // Query is continuing, so `line` should be a substructure (or TODO: subquery)
        // Find a way to track where nesting level and corresponding hierarchy
        // I might need a hierarchy parser here

        continue // might not want to continue if we are handling sub queries
      }
    }

    if (!isQuery(line)) {
      // Replace local links with absolute link which server knows how to handle
      line = line.replace('](./resources/', `](/resources/`)
      newLines.push(line)
      continue
    } else {
      // Fetch zettels and add them to the hub
      query = parseQuery(line)
      queryResults = fetchQuery(query, zettels)
      queryStructure = {}
      indent = query.indent
    }
  }

  return newLines
}

export async function indexCategories(categoriesFileName: string) {
  const categoriesRE = /^\s*- ([^#]*) (#.*#)$/
  const lines = readLines(categoriesFileName)
  let match: RegExpMatchArray
  let category: string
  let categories: string[]
  const graph: {[key: string]: Set<string>} = {}
  const sortedGraph: {[key: string]: string[]} = {}

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
export async function indexArticles(projectDir: string): Promise<Articles> {
  let match: RegExpMatchArray
  const articles: Articles = {names: new Set(), tags: new Set(), ids: {}}

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
          articles.ids[file] = {name: null, tags: []}
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
