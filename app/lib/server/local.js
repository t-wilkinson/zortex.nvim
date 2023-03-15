"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.run = void 0;
const tslib_1 = require("tslib");
const wiki_1 = tslib_1.__importDefault(require("./wiki"));
const buffer_1 = tslib_1.__importStar(require("./buffer"));
const server_1 = require("./server");
const opener_1 = tslib_1.__importDefault(require("../util/opener"));
const http = tslib_1.__importStar(require("http"));
const socket_io_1 = tslib_1.__importDefault(require("socket.io"));
const getIP_1 = require("../util/getIP");
const wiki = tslib_1.__importStar(require("../zortex/wiki"));
// TODO: move app/nvim.js to here?
const openUrl = (plugin, url, browser = null) => {
    const handler = (0, opener_1.default)(url, browser);
    handler.on('error', (err) => {
        const message = err.message || '';
        const match = message.match(/\s*spawn\s+(.+)\s+ENOENT\s*/);
        if (match) {
            plugin.nvim.call('zortex#util#echo_messages', ['Error', [`[zortex.nvim]: Can not open browser by using ${match[1]} command`]]);
        }
        else {
            plugin.nvim.call('zortex#util#echo_messages', ['Error', [err.name, err.message]]);
        }
    });
};
function run({ plugin, logger }) {
    let clients = {};
    // don't await to decrease startup time but requires awaiting any reference
    const articles = plugin.nvim
        .getVar('zortex_notes_dir')
        .then((notesDir) => wiki.getArticles(notesDir));
    // http server
    const server = http.createServer((req, res) => tslib_1.__awaiter(this, void 0, void 0, function* () {
        req.logger = logger;
        req.plugin = plugin;
        // request path
        req.asPath = req.url.replace(/[?#].*$/, '');
        req.mkcss = yield plugin.nvim.getVar('zortex_markdown_css');
        req.hicss = yield plugin.nvim.getVar('zortex_highlight_css');
        // zortex
        req.notesDir = yield plugin.nvim.getVar('zortex_notes_dir');
        req.extension = yield plugin.nvim.getVar('zortex_extension');
        req.articles = yield articles;
        // routes
        (0, server_1.listener)(req, res, [...wiki_1.default.routes, ...buffer_1.default.routes]);
    }));
    server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
            return;
        }
        else {
            throw e;
        }
    });
    // websocket server
    const io = (0, socket_io_1.default)(server);
    io.on('connection', (client) => {
        logger.info('client connect: ', client.id);
        clients[client.id] = client;
        (0, buffer_1.onWebsocketConnection)(logger, client, plugin);
        client.on('disconnect', () => {
            logger.info('disconnect: ', client.id);
            delete clients[client.id];
        });
    });
    function refreshPage({ data }) {
        logger.info('refresh page: ', data.name);
        Object.values(clients).forEach((c) => {
            if (c.connected) {
                c.emit('refresh_content', data);
            }
        });
    }
    function openBrowser({}) {
        return tslib_1.__awaiter(this, void 0, void 0, function* () {
            const openToTheWord = yield plugin.nvim.getVar('zortex_open_to_the_world');
            let port = yield plugin.nvim.getVar('zortex_port');
            port = port || (8080 + Number(`${Date.now()}`.slice(-3)));
            const openIp = yield plugin.nvim.getVar('zortex_open_ip');
            const openHost = openIp !== '' ? openIp : (openToTheWord ? (0, getIP_1.getIP)() : 'localhost');
            const url = `http://${openHost}:${port}/buffer`;
            const browserfunc = yield plugin.nvim.getVar('zortex_browserfunc');
            if (browserfunc !== '') {
                logger.info(`open page [${browserfunc}]: `, url);
                plugin.nvim.call(browserfunc, [url]);
            }
            else {
                const browser = yield plugin.nvim.getVar('zortex_browser');
                logger.info(`open page [${browser || 'default'}]: `, url);
                if (browser !== '') {
                    openUrl(plugin, url, browser);
                }
                else {
                    openUrl(plugin, url);
                }
            }
            const isEchoUrl = yield plugin.nvim.getVar('zortex_echo_preview_url');
            if (isEchoUrl) {
                plugin.nvim.call('zortex#util#echo_url', [url]);
            }
        });
    }
    function startServer() {
        return tslib_1.__awaiter(this, void 0, void 0, function* () {
            const openToTheWord = yield plugin.nvim.getVar('zortex_open_to_the_world');
            const host = openToTheWord ? '0.0.0.0' : '127.0.0.1';
            let port = yield plugin.nvim.getVar('zortex_port');
            port = port || (8080 + Number(`${Date.now()}`.slice(-3)));
            server.listen({
                host,
                port,
            }, () => {
                logger.info('server run: ', port);
                plugin.init({
                    refreshPage,
                    openBrowser,
                });
                // plugin.nvim.call('zortex#util#open_browser')
            });
        });
    }
    startServer();
}
exports.run = run;
