import { attach, Attach, NeovimClient } from '@chemzqm/neovim'
import * as path from 'path'

const zortex = require('../zortex') // tslint:disable-line
const logger = require('../util/logger')('attach') // tslint:disable-line

interface IApp {
  refreshPage: (param: { bufnr: number | string; data: any }) => void
  closePage: (params: { bufnr: number | string }) => void
  closeAllPages: () => void
  openBrowser: (params: { bufnr: number | string }) => void
}

export interface IPlugin {
  init: (app: IApp) => void
  nvim: NeovimClient
}

let app: IApp

export default function (options: Attach): IPlugin {
  const nvim: NeovimClient = attach(options)

  nvim.on('notification', async (method: string, args: any[]) => {
    const opts = args[0] || args
    const bufnr = opts.bufnr
    const buffers = await nvim.buffers
    const buffer = buffers.find((b) => b.id === bufnr)

    const notesDir = await nvim.getVar('zortex_notes_dir')
    const extension = await nvim.getVar('zortex_extension')
    const zettels = await zortex.indexZettels(
      // @ts-ignore
      path.join(notesDir, 'zettels' + extension)
    )

    if (method === 'refresh_content') {
      const winline = await nvim.call('winline')
      const currentWindow = await nvim.window
      const winheight = await nvim.call('winheight', currentWindow.id)
      const cursor = await nvim.call('getpos', '.')
      const renderOpts = await nvim.getVar('zortex_preview_options')
      const pageTitle = await nvim.getVar('zortex_page_title')
      const theme = await nvim.getVar('zortex_theme')
      const name = await buffer.name
      const bufferLines = await buffer.getLines()
      const content = await zortex.populateHub(bufferLines, zettels)
      const currentBuffer = await nvim.buffer
      app.refreshPage({
        bufnr,
        data: {
          options: renderOpts,
          isActive: currentBuffer.id === buffer.id,
          winline,
          winheight,
          cursor,
          pageTitle,
          theme,
          name,
          content,
          zettels,
        },
      })
    } else if (method === 'close_page') {
      app.closePage({
        bufnr,
      })
    } else if (method === 'open_browser') {
      app.openBrowser({
        bufnr,
      })
    }
  })

  nvim.on('request', (method: string, args: any, resp: any) => {
    if (method === 'close_all_pages') {
      app.closeAllPages()
    }
    resp.send()
  })

  nvim.channelId
    .then(async (channelId) => {
      await nvim.setVar('zortex_node_channel_id', channelId)
    })
    .catch((e) => {
      logger.error('channelId: ', e)
    })

  return {
    nvim,
    init: (param: IApp) => {
      app = param
    },
  }
}
