import * as path from 'path'
import {Env} from './types'
import {indexCategories, populateHub, indexZettels} from './zettel'
import {inspect, readLines, allRelatedTags} from './helpers'
import {executeCommand, repl} from './repl'

function parseArgs(args: string[]) {
  const env: Env = {
    onlyTags: false,
    relatedTags: false,
    repl: false,
    missingTags: false,
    command: null,

    extension: '.zortex',
    zettelsFile: 'zettels.zortex',
    // categoriesFile: 'categories.zortex',
    structuresFile: 'structure.zortex',
    noteFile: '',
    projectDir: `${process.env.HOME}/zortex`,

    zettels: null,
    categoriesGraph: null,
  }

  let i = 0

  function nextArg() {
    i++
    return args[i]
  }

  while (i < args.length) {
    switch (args[i]) {
      case '--command':
      case '-c':
        env.command = nextArg()
        break
      // case '--categories':
      // env.categoriesFile = nextArg()
      // break
      case '--zettels':
      case '-z':
        env.zettelsFile = nextArg()
        break
      case '--note':
      case '-n':
        env.noteFile = nextArg()
        break
      case '--project-dir':
      case '-p':
        env.projectDir = nextArg()
        break

      case '--missing-tags':
        env.missingTags = true
        break
      case '--repl':
        env.repl = true
        break
      case '--related-tags':
        env.relatedTags = true
        break
      case '--only-tags':
        env.onlyTags = true
        break
      default:
        throw new Error(`Unknown argument: ${args[i]}`)
    }
    i++
  }

  return env
}

async function setupEnv(env: Env): Promise<Env> {
  function resolveFile(key: string) {
    if (env[key]) {
      env[key] = path.resolve(env.projectDir, env[key])
    }
  }

  resolveFile('structuresFile')
  // resolveFile('categoriesFile')
  resolveFile('zettelsFile')
  resolveFile('noteFile')

  if (env.zettelsFile) {
    env.zettels = await indexZettels(env.zettelsFile)
  }

  return env
}

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
