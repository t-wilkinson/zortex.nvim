import * as fs from 'fs'
import * as url from 'url'
import {findArticle, searchArticles} from '../zortex/wiki'
import {getArticleStructures, getMatchingStructures} from '../zortex/structures'
import {ServerRequest, Routes} from './server'

const routes: Routes<ServerRequest> = [
  // /wiki/structures/:name
  async (req, res, next) => {
    let match: null | string[]
    if (match = req.asPath.match(/wiki\/structures\/([^/]+)/)) {
      const articleName = match[1]
      const notesDir = req.notesDir
      const extension = req.extension
      const structures = await getArticleStructures(notesDir, extension)
      const matchingStructures = getMatchingStructures(articleName, structures)

      res.setHeader('Content-Type', 'application/json')
      return res.end(
        JSON.stringify(
          matchingStructures,
          null,
          0
        )
      )
    }
    next()
  },

  // /wiki/article/:name
  async (req, res, next) => {
    let match: null | string[]
    if (match = req.asPath.match(/wiki\/article\/([^/]+)/)) {
      const articleName = match[1]
      const notesDir = req.notesDir
      const extension = req.extension

      res.setHeader('Content-Type', 'application/json')
      return res.end(
        JSON.stringify(
          await findArticle(notesDir, extension, articleName, req.articles),
          null,
          0
        )
      )
    }
    next()
  },

  // /wiki/search?query
  (req, res, next) => {
    if (/\/wiki\/search/.test(req.asPath)) {
      const searchParams = url.parse(req.url, true).query
      let searchQuery = searchParams['query']
      if (Array.isArray(searchQuery)) {
        searchQuery = searchQuery.join(' ')
      }

      const articles = searchArticles(req.articles, searchQuery)
      res.setHeader('Content-Type', 'application/json')
      return res.end(JSON.stringify(articles, null, 0))
    }
    next()
  },

  // /wiki/:name
  (req, res, next) => {
    if (/\/wiki\/([^/]+)/.test(req.asPath)) {
      return fs.createReadStream('out/wiki.html').pipe(res)
    }
    next()
  },
]

export default {
  routes,
}
