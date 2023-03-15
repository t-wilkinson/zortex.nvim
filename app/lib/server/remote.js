"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.run = void 0;
const tslib_1 = require("tslib");
const server_1 = require("./server");
const wiki_1 = tslib_1.__importDefault(require("./wiki"));
const wiki = tslib_1.__importStar(require("../zortex/wiki"));
const http = tslib_1.__importStar(require("http"));
function run({ logger }) {
    // don't await to decrease startup time but requires awaiting any reference
    const articles = wiki.getArticles(process.env.NOTES_DIR);
    const server = http.createServer((req, res) => tslib_1.__awaiter(this, void 0, void 0, function* () {
        req.logger = logger;
        req.asPath = req.url.replace(/[?#].*$/, '');
        req.notesDir = process.env.NOTES_DIR;
        req.extension = process.env.EXTENSION;
        req.articles = yield articles;
        // routes
        (0, server_1.listener)(req, res, wiki_1.default.routes);
    }));
    function startServer() {
        return tslib_1.__awaiter(this, void 0, void 0, function* () {
            const host = '0.0.0.0';
            const port = process.env.PORT;
            server.listen({
                host,
                port,
            }, () => {
                logger.info('server run: ', port);
            });
        });
    }
    startServer();
}
exports.run = run;
