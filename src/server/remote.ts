import { listener, RemoteRequest } from './server'
import wikiServer from './wiki'
import * as wiki from '../zortex/wiki'
import * as http from 'http'

const config = {
  notesDir: './notes',
  extension: 'zortex',
}

export function run({}) {
  // don't await to decrease startup time but requires awaiting any reference
  const articles = wiki.getArticles(config.notesDir)

  const server = http.createServer(async (req: RemoteRequest, res) => {
    req.asPath = req.url.replace(/[?#].*$/, '')

    req.notesDir = config.notesDir
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
    })
  }

  startServer()
}
