import * as fs from 'fs'
import * as path from 'path'
import {indexZettels, populateHub} from './zettel'

import {getFirstLine} from './helpers'

export interface Article {
  title: string
  fileName: string
  slug: string
}
export type Articles = {[slug: string]: Article}

const slugifyArticleName = (articleName: string) => {
  return articleName.replace(/ /g, '_')
}

const parseArticleTitle = (titleLine: string) => {
  let title = titleLine.replace(/^@+/, '')

  // if article title is a link, extract the name
  // [name](link)
  if (title.charAt(0) === '[') {
    const match = title.match(/^\[([^\]]+)]/) // \([^)]+\)$/)
    if (match) {
      title = match[1]
    }
  }

  return {
    title,
    slug: slugifyArticleName(title),
  }
}

export async function getArticles(notesDir: string): Promise<Articles> {
  const articles = {}

  // get article names
  const fileNames = fs
    .readdirSync(notesDir, {withFileTypes: true})
    .filter((item) => !item.isDirectory())
    .map((item) => item.name)

  for await (const fileName of fileNames) {
    const line = await getFirstLine(path.join(notesDir, fileName))
    const article = parseArticleTitle(line)

    articles[article.slug] = {
      title: article.title,
      fileName,
      slug: article.slug,
    }
  }

  return articles
}

export function matchArticle(
  notesDir: string,
  articleName: string,
  articles: Articles
) {
  const slug = slugifyArticleName(articleName)
  const article = articles[slug]
  if (!article) {
    return null
  }

  const content = fs
    .readFileSync(path.join(notesDir, article.fileName))
    .toString()
    .split('\n')
  return {
    ...article,
    content,
  }
}

export function searchArticles(articles: Articles, search: string) {
  if (search === '') {
    return []
  }

  const terms = slugifyArticleName(search)
    .toLowerCase()
    .split(/[ _-]/)
    .filter((x) => x)

  const matches = Object.values(articles).reduce((acc, article) => {
    const slug = slugifyArticleName(article.title).toLowerCase()
    if (terms.every((term) => slug.includes(term))) {
      acc.push(article)
    }
    return acc
  }, [])

  return matches.sort((a, b) => (a.slug < b.slug) ? -1 : (a.slug > b.slug) ? 1 : 0)
}

export async function findArticle(notesDir: string, extension: string, articleName: string, articles: Articles) {
  const article = matchArticle(notesDir, articleName, articles)
  if (!article) {
    return null
  }

  const zettels = await indexZettels(path.join(notesDir, 'zettels' + extension))
  const content = await populateHub(article.content, zettels, notesDir)

  return {
    articleName,
    ...article,
    content,
  }
}
