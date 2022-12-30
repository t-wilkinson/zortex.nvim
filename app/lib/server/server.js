"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.staticRoutes = exports.listener = void 0;
const tslib_1 = require("tslib");
const fs = tslib_1.__importStar(require("fs"));
const path = tslib_1.__importStar(require("path"));
function listener(req, res, routes) {
    // TODO: extract the map to outside http.createServer() to speed up each request
    ;
    [...routes, ...exports.staticRoutes]
        .reverse()
        .map(route => (req, res, next) => () => route(req, res, next))
        .reduce((next, route) => route(req, res, next), undefined)();
}
exports.listener = listener;
exports.staticRoutes = [
    // /resources
    (req, res, next) => {
        if (/\/resources/.test(req.asPath)) {
            const filepath = path.join(req.notesDir, req.asPath);
            if (fs.existsSync(filepath)) {
                return fs.createReadStream(path.join('./out', '404.html')).pipe(res);
            }
            else {
                return fs.createReadStream(filepath).pipe(res);
            }
        }
        next();
    },
    // /_next/path
    (req, res, next) => {
        if (/\/_next/.test(req.asPath)) {
            return fs.createReadStream(path.join('./out', req.asPath)).pipe(res);
        }
        next();
    },
    // /_static/markdown.css
    // /_static/highlight.css
    (req, res, next) => {
        try {
            if (req.mkcss && req.asPath === '/_static/markdown.css') {
                if (fs.existsSync(req.mkcss)) {
                    return fs.createReadStream(req.mkcss).pipe(res);
                }
            }
            else if (req.hicss && req.asPath === '/_static/highlight.css') {
                if (fs.existsSync(req.hicss)) {
                    return fs.createReadStream(req.hicss).pipe(res);
                }
            }
        }
        catch (e) {
            req.logger.error('load diy css fail: ', req.asPath, req.mkcss, req.hicss);
        }
        next();
    },
    // /_static/path
    (req, res, next) => {
        if (/\/_static/.test(req.asPath)) {
            const fpath = path.join('./', req.asPath);
            if (fs.existsSync(fpath)) {
                return fs.createReadStream(fpath).pipe(res);
            }
            else {
                req.logger.error('No such file:', req.asPath, req.mkcss, req.hicss);
            }
        }
        next();
    },
    // images
    (req, res, next) => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
        req.logger.info('image route: ', req.asPath);
        const reg = /^\/_local_image_/;
        if (reg.test(req.asPath) && req.asPath !== '') {
            const plugin = req.plugin;
            const buffers = yield plugin.nvim.buffers;
            const buffer = buffers.find(b => b.id === Number(req.bufnr));
            if (buffer) {
                const fileDir = yield plugin.nvim.call('expand', `#${req.bufnr}:p:h`);
                req.logger.info('fileDir', fileDir);
                let imgPath = decodeURIComponent(decodeURIComponent(req.asPath.replace(reg, '')));
                imgPath = imgPath.replace(/\\ /g, ' ');
                if (imgPath[0] !== '/' && imgPath[0] !== '\\') {
                    imgPath = path.join(fileDir, imgPath);
                }
                else if (!fs.existsSync(imgPath)) {
                    let tmpDirPath = fileDir;
                    while (tmpDirPath !== '/' && tmpDirPath !== '\\') {
                        tmpDirPath = path.normalize(path.join(tmpDirPath, '..'));
                        let tmpImgPath = path.join(tmpDirPath, imgPath);
                        if (fs.existsSync(tmpImgPath)) {
                            imgPath = tmpImgPath;
                            break;
                        }
                    }
                }
                req.logger.info('imgPath', imgPath);
                if (fs.existsSync(imgPath) && !fs.statSync(imgPath).isDirectory()) {
                    if (imgPath.endsWith('svg')) {
                        res.setHeader('content-type', 'image/svg+xml');
                    }
                    return fs.createReadStream(imgPath).pipe(res);
                }
                req.logger.error('image not exists: ', imgPath);
            }
        }
        next();
    }),
    // 404
    (req, res) => {
        res.statusCode = 404;
        return fs.createReadStream(path.join('./out', '404.html')).pipe(res);
    },
];
