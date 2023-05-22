import {Env} from './types'
import {indexCategories, populateHub, indexZettels} from './zettel'
import {inspect, readLines, allRelatedTags} from './helpers'
import {executeCommand, repl} from './repl'
import {getArticleStructures} from './structures'
import {setupEnv, parseArgs} from './env'

export async function run() {
  const env = await setupEnv(parseArgs(process.argv.slice(2)))

  if (env.command) {
    // env.categoriesGraph = await indexCategories(env.categoriesFile)
    return executeCommand(env.command, () => {}, env, null)
  }

  // REPL
  if (env.repl) {
    return repl(env)
  }

  // Show related tags
  if (env.relatedTags) {
    return inspect(allRelatedTags(env.zettels))
  }

  if (env.missingTags) {
    const hubTags: Set<string> = new Set()
    const lines = readLines(env.noteFile)
    const tagRE = /- ([a-z0-9][a-z0-9=-]*)/
    const zettelIdRE = /z:[0-9.]+/
    for await (const line of lines) {
      const match = line.match(tagRE)
      if (!match) {
        continue
      }
      hubTags.add(match[1])
    }
    const missingTags = [...Object.keys(env.zettels.tags)]
      .filter((tag) => {
        return !hubTags.has(tag) && !zettelIdRE.test(tag)
      })
      .sort()
    console.log(missingTags)
    return
  }

  // Show tag count of all zettels
  if (env.onlyTags) {
    let tags: {[key: string]: number}
    tags = Object.entries(env.zettels.tags).reduce((acc, [tag, zettels]) => {
      acc[tag] = zettels.size
      return acc
    }, {})
    tags = Object.fromEntries(
      Object.entries(tags).sort(([, a], [, b]) => a - b)
    )
    for (const [zettel, count] of Object.entries(tags)) {
      console.log(`\x1b[36m${zettel}: \x1b[0m${count}`)
    }
    return
  }

  if (env.structures) {
    const structures = await getArticleStructures(env.projectDir, env.extension)
    inspect(structures)
    return
  }

  // Show indexed zettels
  if (!env.noteFile) {
    console.log(env.zettels)
    return
  }

  // Populate hub with zettels
  if (env.noteFile && env.zettelsFile) {
    const lines = readLines(env.noteFile)
    const populatedHub = await populateHub(lines, env.zettels, env.projectDir)
    inspect(populatedHub)
    return
  }
}

