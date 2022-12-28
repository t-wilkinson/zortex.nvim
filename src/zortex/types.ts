export interface Query {
  tags: string[]
}

export interface Articles {
  names: Set<string>
  tags: Set<string>
  ids: { [id: string]: { name: string; tags: string[] } }
}

export interface Zettels {
  tags: { [key: string]: Set<string> }
  ids: {
    [key: string]: {
      tags: string[]
      content: string | string[]
      lineNumber: number
    }
  }
}

export interface Env {
  onlyTags: boolean
  relatedTags: boolean
  repl: boolean
  missingTags: boolean
  command?: string

  extension: string
  zettelsFile: string
  structuresFile: string
  // categoriesFile: string
  noteFile: string
  projectDir: string

  zettels: Zettels
  categoriesGraph: { [key: string]: string[] }
}
