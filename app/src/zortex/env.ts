import * as path from 'path'

import {Env} from './types'
import { indexZettels } from './zettel'

// TODO: move cli specific logic into cli
export function parseArgs(args: string[]) {
  const env: Env = {
    onlyTags: false,
    relatedTags: false,
    repl: false,
    missingTags: false,
    structures: false,
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

      case '--structures':
        env.structures = true
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


export async function setupEnv(env: Env): Promise<Env> {
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

