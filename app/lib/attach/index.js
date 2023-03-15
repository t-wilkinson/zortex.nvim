"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const tslib_1 = require("tslib");
const neovim_1 = require("@chemzqm/neovim");
const path = tslib_1.__importStar(require("path"));
const wiki_1 = require("../zortex/wiki");
const zettel_1 = require("../zortex/zettel"); // tslint:disable-line
const logger = require('../util/logger')('attach'); // tslint:disable-line
let app;
function default_1(options) {
    const nvim = (0, neovim_1.attach)(options);
    nvim.on('notification', (method, args) => tslib_1.__awaiter(this, void 0, void 0, function* () {
        const buffer = yield nvim.buffer;
        const notesDir = yield nvim.getVar('zortex_notes_dir');
        const extension = yield nvim.getVar('zortex_extension');
        const zettels = yield (0, zettel_1.indexZettels)(
        // @ts-ignore
        path.join(notesDir, 'zettels' + extension));
        if (method === 'refresh_content') {
            const winline = yield nvim.call('winline');
            const currentWindow = yield nvim.window;
            const winheight = yield nvim.call('winheight', currentWindow.id);
            const cursor = yield nvim.call('getpos', '.');
            const renderOpts = yield nvim.getVar('zortex_preview_options');
            const pageTitle = yield nvim.getVar('zortex_page_title');
            const theme = yield nvim.getVar('zortex_theme');
            const name = yield buffer.name;
            const bufferLines = yield buffer.getLines();
            const content = yield (0, zettel_1.populateHub)(bufferLines, zettels, notesDir.toString());
            const articleTitle = (0, wiki_1.parseArticleTitle)(bufferLines[0]);
            app === null || app === void 0 ? void 0 : app.refreshPage({
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
            });
        }
        else if (method === 'open_browser') {
            app === null || app === void 0 ? void 0 : app.openBrowser({});
        }
    }));
    //   nvim.on('request', (method: string, args: any, resp: any) => {
    //     if (method === 'close_all_pages') {
    //       app?.closeAllPages()
    //     }
    //     resp.send()
    //   })
    nvim.channelId
        .then((channelId) => tslib_1.__awaiter(this, void 0, void 0, function* () {
        yield nvim.setVar('zortex_node_channel_id', channelId);
    }))
        .catch((e) => {
        logger.error('channelId: ', e);
    });
    return {
        nvim,
        init: (param) => {
            app = param;
        },
    };
}
exports.default = default_1;
