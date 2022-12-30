import * as fs from 'fs'
import * as path from 'path'
import * as zortex from '../zortex'
import {LocalRequest, Routes} from './server'

const routes: Routes<LocalRequest> = [
  // /buffer
  (req, res, next) => {
    if (/^\/buffer$/.test(req.asPath)) {
      return fs.createReadStream('./out/buffer.html').pipe(res)
    }
    next()
  },
]

export const onWebsocketConnection = async (logger, client, plugin) => {
  const notesDir = await plugin.nvim.getVar('zortex_notes_dir')
  const extension = await plugin.nvim.getVar('zortex_extension')
  const zettels = await zortex.indexZettels(path.join(notesDir, 'zettels' + extension))

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
  const content = await zortex.populateHub(bufferLines, zettels, notesDir)

  client.emit('refresh_content', {
    options,
    isActive: true,
    winline,
    winheight,
    cursor,
    pageTitle,
    theme,
    name,
    content,
    zettels,
  })
}

export default {
  routes,
}
