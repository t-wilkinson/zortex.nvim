import * as fs from 'fs'
import * as path from 'path'
// import {indexZettels, populateHub} from '../zortex/zettel'
import {parseArticleTitle} from '../zortex/wiki'
import {getArticleFilepath} from '../zortex/helpers'
import {LocalRequest, Routes} from './server'

const routes: Routes<LocalRequest> = [
  // /buffer
  (req, res, next) => {
    if (/^\/buffer$/.test(req.asPath)) {
      return fs.createReadStream('out/buffer.html').pipe(res)
    }
    next()
  },
]

const getRefreshContent = async (plugin) => {
  // const notesDir = await plugin.nvim.getVar('zortex_notes_dir')
  // const extension = await plugin.nvim.getVar('zortex_extension')
  // const zettels = await indexZettels(path.join(notesDir, 'zettels' + extension))

  const buffer = await plugin.nvim.buffer
  const winline = await plugin.nvim.call('winline')
  const currentWindow = await plugin.nvim.window
  const winheight = await plugin.nvim.call('winheight', currentWindow.id)
  const cursor = await plugin.nvim.call('getpos', '.')
  const options = await plugin.nvim.getVar('zortex_preview_options')
  const pageTitle = await plugin.nvim.getVar('zortex_page_title')
  const theme = await plugin.nvim.getVar('zortex_theme')
  const name = await buffer.name
  const bufferLines = await buffer.getLines()
  const content = bufferLines // await populateHub(bufferLines, zettels, notesDir)

  const articleTitle = parseArticleTitle(bufferLines[0])

  return {
    options,
    isActive: true,
    winline,
    winheight,
    cursor,
    pageTitle,
    theme,
    name,
    content,
    zettels: [],
    articleTitle,
  }
}

export const onWebsocketConnection = async (logger, client, plugin) => {
  client.emit('refresh_content', await getRefreshContent(plugin))

  client.on('change_page', async (articleName: string) => {
    const notesDir = await plugin.nvim.getVar('zortex_notes_dir')
    const filepath = await getArticleFilepath(notesDir, articleName)
    if (filepath) {
      plugin.nvim.command(`edit ${filepath}`)
        .then(async () => {
          client.emit('refresh_content', await getRefreshContent(plugin))
        })
    }
  })
}

export default {
  routes,
}
