"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const tslib_1 = require("tslib");
const fs = tslib_1.__importStar(require("fs"));
const url = tslib_1.__importStar(require("url"));
const wiki = tslib_1.__importStar(require("../zortex/wiki"));
const routes = [
    // /wiki/article/:name
    (req, res, next) => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
        let match;
        if (match = req.asPath.match(/wiki\/article\/([^/]+)/)) {
            const articleName = match[1];
            const notesDir = req.notesDir;
            const extension = req.extension;
            res.setHeader('Content-Type', 'application/json');
            return res.end(JSON.stringify(yield wiki.findArticle(notesDir, extension, articleName, req.articles), null, 0));
        }
        next();
    }),
    // /wiki/search?query
    (req, res, next) => {
        if (/\/wiki\/search/.test(req.asPath)) {
            const searchParams = url.parse(req.url, true).query;
            let searchQuery = searchParams['query'];
            if (Array.isArray(searchQuery)) {
                searchQuery = searchQuery.join(' ');
            }
            const articles = wiki.searchArticles(req.articles, searchQuery);
            res.setHeader('Content-Type', 'application/json');
            return res.end(JSON.stringify(articles, null, 0));
        }
        next();
    },
    // /wiki/:name
    (req, res, next) => {
        if (/\/wiki\/([^/]+)/.test(req.asPath)) {
            return fs.createReadStream('./out/wiki.html').pipe(res);
        }
        next();
    },
];
exports.default = {
    routes,
};
