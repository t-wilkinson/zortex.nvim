"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.onWebsocketConnection = void 0;
const tslib_1 = require("tslib");
const fs = tslib_1.__importStar(require("fs"));
const path = tslib_1.__importStar(require("path"));
const zettel_1 = require("../zortex/zettel");
const wiki_1 = require("../zortex/wiki");
const helpers_1 = require("../zortex/helpers");
const routes = [
    // /buffer
    (req, res, next) => {
        if (/^\/buffer$/.test(req.asPath)) {
            return fs.createReadStream('./out/buffer.html').pipe(res);
        }
        next();
    },
];
const getRefreshContent = (plugin) => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
    const notesDir = yield plugin.nvim.getVar('zortex_notes_dir');
    const extension = yield plugin.nvim.getVar('zortex_extension');
    const zettels = yield (0, zettel_1.indexZettels)(path.join(notesDir, 'zettels' + extension));
    const buffer = yield plugin.nvim.buffer;
    const winline = yield plugin.nvim.call('winline');
    const currentWindow = yield plugin.nvim.window;
    const winheight = yield plugin.nvim.call('winheight', currentWindow.id);
    const cursor = yield plugin.nvim.call('getpos', '.');
    const options = yield plugin.nvim.getVar('zortex_preview_options');
    const pageTitle = yield plugin.nvim.getVar('zortex_page_title');
    const theme = yield plugin.nvim.getVar('zortex_theme');
    const name = yield buffer.name;
    const bufferLines = yield buffer.getLines();
    const content = yield (0, zettel_1.populateHub)(bufferLines, zettels, notesDir);
    const articleTitle = (0, wiki_1.parseArticleTitle)(bufferLines[0]);
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
        zettels,
        articleTitle,
    };
});
const onWebsocketConnection = (logger, client, plugin) => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
    client.emit('refresh_content', yield getRefreshContent(plugin));
    client.on('change_page', (articleName) => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
        const notesDir = yield plugin.nvim.getVar('zortex_notes_dir');
        const filepath = yield (0, helpers_1.getArticleFilepath)(notesDir, articleName);
        if (filepath) {
            plugin.nvim.command(`edit ${filepath}`)
                .then(() => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
                client.emit('refresh_content', yield getRefreshContent(plugin));
            }));
        }
    }));
});
exports.onWebsocketConnection = onWebsocketConnection;
exports.default = {
    routes,
};
