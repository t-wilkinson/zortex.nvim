import * as fs from 'fs'
import * as path from 'path'

import {Logger} from 'log4js'
import {IPlugin} from '../attach'
import {IncomingMessage, ServerResponse} from 'http'
import {Articles} from '../zortex/wiki'

export type RemoteRequest = IncomingMessage & {
  asPath: string

  extension: string
  notesDir: string
  articles: Articles
}

export type LocalRequest = IncomingMessage & {
  plugin: IPlugin
  logger: Logger

  bufnr: string
  asPath: string

  mkcss: string
  hicss: string

  notesDir: string
  extension: string
  articles: Articles
}

export type ServerRequest = RemoteRequest | LocalRequest

export type Route<Request> = (req: Request, res: ServerResponse, next: () => Route<Request>) => any
export type Routes<Request> = Route<Request>[]

export function listener<Request>(req: Request, res: ServerResponse, routes: Routes<Request>) {
  // TODO: extract the map to outside http.createServer() to speed up each request
  ;[...routes, ...staticRoutes]
    .reverse()
    .map(route => (req, res, next) => () => route(req, res, next))
    .reduce((next, route) => route(req, res, next), undefined as any)()
}

export const staticRoutes: Routes<LocalRequest> = [
  // /resources
  (req, res, next) => {
    if (/\/resources/.test(req.asPath)) {
      const filepath = path.join(req.notesDir, req.asPath)
      if (fs.existsSync(filepath)) {
        return fs.createReadStream(filepath).pipe(res)
      } else {
        return fs.createReadStream(path.join('./out', '404.html')).pipe(res)
      }
    }
    next()
  },

  // /_next/path
  (req, res, next) => {
    if (/\/_next/.test(req.asPath)) {
      return fs.createReadStream(path.join('./out', req.asPath)).pipe(res)
    }
    next()
  },

  // /_static/markdown.css
  // /_static/highlight.css
  (req, res, next) => {
    try {
      if (req.mkcss && req.asPath === '/_static/markdown.css') {
        if (fs.existsSync(req.mkcss)) {
          return fs.createReadStream(req.mkcss).pipe(res)
        }
      } else if (req.hicss && req.asPath === '/_static/highlight.css') {
        if (fs.existsSync(req.hicss)) {
          return fs.createReadStream(req.hicss).pipe(res)
        }
      }
    } catch (e) {
      req.logger.error('load diy css fail: ', req.asPath, req.mkcss, req.hicss)
    }
    next()
  },

  // /_static/path
  (req, res, next) => {
    if (/\/_static/.test(req.asPath)) {
      const fpath = path.join('./', req.asPath)
      if (fs.existsSync(fpath)) {
        return fs.createReadStream(fpath).pipe(res)
      } else {
        req.logger.error('No such file:', req.asPath, req.mkcss, req.hicss)
      }
    }
    next()
  },

  // images
  async (req, res, next) => {
    req.logger.info('image route: ', req.asPath)
    const reg = /^\/_local_image_/
    if (reg.test(req.asPath) && req.asPath !== '') {
      const plugin = req.plugin
      const buffers = await plugin.nvim.buffers
      const buffer = buffers.find(b => b.id === Number(req.bufnr))
      if (buffer) {
        const fileDir = await plugin.nvim.call('expand', `#${req.bufnr}:p:h`)
        req.logger.info('fileDir', fileDir)
        let imgPath = decodeURIComponent(decodeURIComponent(req.asPath.replace(reg, '')))
        imgPath = imgPath.replace(/\\ /g, ' ')
        if (imgPath[0] !== '/' && imgPath[0] !== '\\') {
          imgPath = path.join(fileDir, imgPath)
        } else if (!fs.existsSync(imgPath)) {
          let tmpDirPath = fileDir
          while (tmpDirPath !== '/' && tmpDirPath !== '\\') {
            tmpDirPath = path.normalize(path.join(tmpDirPath, '..'))
            let tmpImgPath = path.join(tmpDirPath, imgPath)
            if (fs.existsSync(tmpImgPath)) {
              imgPath = tmpImgPath
              break
            }
          }
        }
        req.logger.info('imgPath', imgPath)
        if (fs.existsSync(imgPath) && !fs.statSync(imgPath).isDirectory()) {
          if (imgPath.endsWith('svg')) {
            res.setHeader('content-type', 'image/svg+xml')
          }
          return fs.createReadStream(imgPath).pipe(res)
        }
        req.logger.error('image not exists: ', imgPath)
      }
    }
    next()
  },

  // 404
  (req, res) => {
    res.statusCode = 404
    return fs.createReadStream(path.join('./out', '404.html')).pipe(res)
  },
]
