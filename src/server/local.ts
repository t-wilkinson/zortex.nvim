import wikiServer from './wiki'
import bufferServer, {onWebsocketConnection} from './buffer'
import {listener, LocalRequest} from './server'
import opener from '../util/opener'
import * as http from 'http'
import websocket from 'socket.io'
import {getIP} from '../util/getIP'
import * as wiki from '../zortex/wiki'

// TODO: move app/nvim.js to here?
const openUrl = (plugin, url, browser = null) => {
  const handler = opener(url, browser)
  handler.on('error', (err) => {
    const message = err.message || ''
    const match = message.match(/\s*spawn\s+(.+)\s+ENOENT\s*/)
    if (match) {
      plugin.nvim.call('zortex#util#echo_messages', ['Error', [`[zortex.nvim]: Can not open browser by using ${match[1]} command`]])
    } else {
      plugin.nvim.call('zortex#util#echo_messages', ['Error', [err.name, err.message]])
    }
  })
}

export function run({plugin, logger}) {
  let clients = {}

  // don't await to decrease startup time but requires awaiting any reference
  const articles = plugin.nvim
    .getVar('zortex_notes_dir')
    .then((notesDir: string) => wiki.getArticles(notesDir))

  // http server
  const server = http.createServer(async (req: LocalRequest, res) => {
    req.logger = logger
    req.plugin = plugin

    // request path
    req.asPath = req.url.replace(/[?#].*$/, '')
    req.mkcss = await plugin.nvim.getVar('zortex_markdown_css')
    req.hicss = await plugin.nvim.getVar('zortex_highlight_css')

    // zortex
    req.notesDir = await plugin.nvim.getVar('zortex_notes_dir')
    req.extension = await plugin.nvim.getVar('zortex_extension')
    req.articles = await articles

    // routes
    listener(req, res, [...wikiServer.routes, ...bufferServer.routes])
  })

  // websocket server
  const io = websocket(server)
  io.on('connection', (client) => {
    logger.info('client connect: ', client.id)
    clients[client.id] = client

    onWebsocketConnection(logger, client, plugin)

    client.on('disconnect', () => {
      logger.info('disconnect: ', client.id)
      delete clients[client.id]
    })
  })

  function refreshPage({data}) {
    logger.info('refresh page: ', data.name)
    Object.values(clients).forEach((c: any) => {
      if (c.connected) {
        c.emit('refresh_content', data)
      }
    })
  }

  async function openBrowser({}) {
    const openToTheWord = await plugin.nvim.getVar('zortex_open_to_the_world')
    let port = await plugin.nvim.getVar('zortex_port')
    port = port || (8080 + Number(`${Date.now()}`.slice(-3)))

    const openIp = await plugin.nvim.getVar('zortex_open_ip')
    const openHost = openIp !== '' ? openIp : (openToTheWord ? getIP() : 'localhost')
    const url = `http://${openHost}:${port}/buffer`
    const browserfunc = await plugin.nvim.getVar('zortex_browserfunc')
    if (browserfunc !== '') {
      logger.info(`open page [${browserfunc}]: `, url)
      plugin.nvim.call(browserfunc, [url])
    } else {
      const browser = await plugin.nvim.getVar('zortex_browser')
      logger.info(`open page [${browser || 'default'}]: `, url)
      if (browser !== '') {
        openUrl(plugin, url, browser)
      } else {
        openUrl(plugin, url)
      }
    }
    const isEchoUrl = await plugin.nvim.getVar('zortex_echo_preview_url')
    if (isEchoUrl) {
      plugin.nvim.call('zortex#util#echo_url', [url])
    }
  }

  async function startServer() {
    const openToTheWord = await plugin.nvim.getVar('zortex_open_to_the_world')
    const host = openToTheWord ? '0.0.0.0' : '127.0.0.1'
    let port = await plugin.nvim.getVar('zortex_port')
    port = port || (8080 + Number(`${Date.now()}`.slice(-3)))

    server.listen(
      {
        host,
        port,
      },
      () => {
        logger.info('server run: ', port)

        plugin.init({
          refreshPage,
          openBrowser,
        })

        // plugin.nvim.call('zortex#util#open_browser')
      }
    )
  }

  startServer()
}
