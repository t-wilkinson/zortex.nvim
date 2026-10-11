import * as util from 'util'
import * as fs from 'fs'
import * as path from 'path'
import * as readline from 'readline'
import {Zettels} from './types'
import {compareArticle, parseArticleTitle, compareArticleSlugs, slugifyArticleName} from './wiki'

export function inspect(x: any) {
  console.log(
    util.inspect(x, {
      showHidden: false,
      depth: null,
      colors: true,
      maxArrayLength: null,
      breakLength: 3,
      compact: 8,
    })
  )
}

export async function getFirstLine(pathToFile: string): Promise<string> {
  const readable = fs.createReadStream(pathToFile)
  const reader = readline.createInterface({input: readable})
  const firstLine = await new Promise<string>((resolve) => {
    reader.on('line', (line) => {
      reader.close()
      resolve(line)
    })
  })
  readable.close()
  return firstLine
}

export function readLines(filename: string): readline.Interface {
  const fileStream = fs.createReadStream(filename)
  const lines = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity,
  })
  return lines
}

export function relatedTags(zettels: Zettels, tag: string): string[] {
  const relatedTags = new Set<string>()
  zettels.tags[tag]?.forEach((id) => {
    const zettel = zettels.ids[id]
    zettel.tags.forEach((t: string) => {
      if (t !== tag) {
        relatedTags.add(t)
      }
    })
  })

  return [...relatedTags]
}

/**
 * Return which tags each tag is associated with
 */
export function allRelatedTags(zettels: Zettels) {
  let tags = Object.keys(zettels.tags).reduce((acc, tag) => {
    acc[tag] = new Set()
    return acc
  }, {})

  // For each tag, add all tags that are associated with it
  for (const zettel of Object.values(zettels.ids)) {
    for (const tag of zettel.tags) {
      zettel.tags.forEach(tags[tag].add, tags[tag])
    }
  }

  // Convert tags to array
  for (const tag of Object.keys(tags)) {
    tags[tag] = [...tags[tag]]
  }
  return tags
}

export function toSpacecase(str: string) {
  return str.charAt(0).toUpperCase() + str.slice(1).replace(/-/g, ' ')
}

export async function getArticleFilepath(notesDir: string, articleName: string) {
  const articleSlug = slugifyArticleName(articleName)

  // get article files
  const fileNames = fs
    .readdirSync(notesDir, {withFileTypes: true})
    .filter((item) => !item.isDirectory())
    .map((item) => item.name)

  for await (const fileName of fileNames) {
    const filepath = path.join(notesDir, fileName)
    const line = await getFirstLine(filepath)
    const {slug} = parseArticleTitle(line)
    if (compareArticleSlugs(slug, articleSlug)) {
      return filepath
    }
  }
}

export async function getArticleTitle(filepath) {
  const line = await getFirstLine(filepath)
  return parseArticleTitle(line)
}
