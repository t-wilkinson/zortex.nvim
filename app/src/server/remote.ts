import {listener, RemoteRequest} from './server'
import wikiServer from './wiki'
import * as wiki from '../zortex/wiki'
import * as http from 'http'

export function run({logger}) {
  // don't await to decrease startup time but requires awaiting any reference
  const articles = wiki.getArticles(process.env.NOTES_DIR)

  const server = http.createServer(async (req: RemoteRequest, res) => {
    req.logger = logger
    req.asPath = req.url.replace(/[?#].*$/, '')

    req.notesDir = process.env.NOTES_DIR
    req.extension = process.env.EXTENSION
    req.articles = await articles

    // routes
    listener<RemoteRequest>(req, res, wikiServer.routes)
  })

  async function startServer() {
    const host = '0.0.0.0'
    const port = process.env.PORT
    server.listen({
      host,
      port,
    }, () => {
      logger.info('server run: ', port)
    })
  }

  startServer()
}
