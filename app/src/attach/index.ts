import {attach, Attach, NeovimClient} from '@chemzqm/neovim'
import * as path from 'path'

import {parseArticleTitle} from '../zortex/wiki'
import {indexZettels, populateHub} from '../zortex/zettel' // tslint:disable-line
const logger = require('../util/logger')('attach') // tslint:disable-line

interface IApp {
  refreshPage: (param: {data: any}) => void
  openBrowser: (params: {}) => void
}

export interface IPlugin {
  init: (app: IApp) => void
  nvim: NeovimClient
}

let app: IApp

export default function (options: Attach): IPlugin {
  const nvim: NeovimClient = attach(options)

  nvim.on('notification', async (method: string, args: any[]) => {
    const buffer = await nvim.buffer
    // const notesDir = await nvim.getVar('zortex_notes_dir')
    // const extension = await nvim.getVar('zortex_extension')
    // const zettels = await indexZettels(
    //   // @ts-ignore
    //   path.join(notesDir, 'zettels' + extension)
    // )

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
      // const content = await populateHub(bufferLines, zettels, notesDir.toString())
      const content = bufferLines

      const articleTitle = parseArticleTitle(bufferLines[0])

      app?.refreshPage({
        data: {
          options: renderOpts,
          isActive: true,
          winline,
          winheight,
          cursor,
          pageTitle,
          theme,
          name,
          content,
          articleTitle,
        },
      })
    } else if (method === 'open_browser') {
      app?.openBrowser({})
    }
  })

  //   nvim.on('request', (method: string, args: any, resp: any) => {
  //     if (method === 'close_all_pages') {
  //       app?.closeAllPages()
  //     }
  //     resp.send()
  //   })

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
