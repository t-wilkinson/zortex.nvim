import {Query, Zettels} from './types'

const queryRE = /^(\s*)%\s+#(.*)#$/ // % #asdf#asdfa#
const simpleQueryRE = /(\S+)/       // % asdf

export function isQuery(line: string): boolean {
  return queryRE.test(line)
}

// Line is in the form /^\s*- .*$/
export function lineToTag(line: string) {
  return line.trim().toLowerCase().replace(/\s/g, '-')
}

export function parseQuery(queryString: string): Query | null {
  let match = queryString.match(queryRE)

  if (match) {
    const indent = match[1].length
    const query = match[2].trim()

    let tags: string[]
    tags = query.split('#').filter((v) => v)

    return {
      indent,
      tags,
    }
  } else if (match = queryString.match(simpleQueryRE)) {
    return {
      indent: 0,
      tags: [match[1]]
    }
  } else {
    return null
  }
}

export function fetchQuery(query: Query, zettels: Zettels) {
  if (!query) {
    return []
  }

  // Remove tags that aren't found in zettels
  const queryTags = query.tags.filter((tag) => zettels.tags[tag])
  if (queryTags.length === 0) {
    return []
  }

  // Get the tag with smallest number of zettels
  let smallestTag = queryTags[0]
  for (const tag of queryTags) {
    if (zettels.tags[tag].size < zettels.tags[smallestTag].size) {
      smallestTag = tag
    }
  }

  // Keep only zettels which have all tags
  const zettelsWithTags = [...zettels.tags[smallestTag]].filter((id) => {
    return queryTags.every((tag) => zettels.tags[tag].has(id))
  })
  return zettelsWithTags
}

