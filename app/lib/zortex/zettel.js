"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.indexArticles = exports.indexCategories = exports.populateHub = exports.indexZettels = exports.showZettels = exports.toZettel = exports.newZettelId = void 0;
const tslib_1 = require("tslib");
const path = tslib_1.__importStar(require("path"));
const fs = tslib_1.__importStar(require("fs"));
const strftime_1 = tslib_1.__importDefault(require("strftime"));
const helpers_1 = require("./helpers");
const query_1 = require("./query");
function newZettelId() {
    const randInt = (1e5 + Math.random() * 1e5 + '').slice(-5);
    return (0, strftime_1.default)(`z:%H%M.%u%U%g.${randInt}`);
}
exports.newZettelId = newZettelId;
function toZettel(id, tags, content) {
    if (typeof content === 'string') {
        return `[${id}] #${tags.join('#')}# ${content}`;
    }
    else {
        return `[${id}] #${tags.join('#')}# ${content.join('\n')}`;
    }
}
exports.toZettel = toZettel;
function showZettel(id, tags, content) {
    if (typeof content === 'string') {
        return `\x1b[33m[${id}] \x1b[36m#${tags.join('#')}# \x1b[0m${content}`;
    }
    else {
        return `\x1b[33m[${id}] \x1b[36m#${tags.join('#')}# \x1b[0m${content.join('\n')}`;
    }
}
function showZettels(ids, zettels) {
    for (const id of ids) {
        const zettel = zettels.ids[id];
        console.log(showZettel(id, [...zettel.tags], zettel.content));
    }
}
exports.showZettels = showZettels;
function indexZettels(zettelsFile) {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        let lineNumber = 0;
        let id;
        let tags;
        let content;
        const zettels = {
            tags: {},
            ids: {},
        };
        const zettelRE = /^\[(z:[0-9.]*)]\s*(#.*#)?\s*(.*)$/;
        const lines = (0, helpers_1.readLines)(zettelsFile);
        try {
            for (var lines_1 = tslib_1.__asyncValues(lines), lines_1_1; lines_1_1 = yield lines_1.next(), !lines_1_1.done;) {
                const line = lines_1_1.value;
                lineNumber++;
                const match = line.match(zettelRE);
                if (!match) {
                    // If there is no match, merge information with previous zettel
                    if (id) {
                        if (!Array.isArray(zettels.ids[id].content)) {
                            zettels.ids[id].content = [zettels.ids[id].content];
                        }
                        ;
                        zettels.ids[id].content.push(line);
                    }
                    continue;
                }
                //     if (zettels.ids[id].tags?.has('z-source')) {
                //       const source = zettels.ids[id].content
                //       zettels.ids[id].content =
                //         typeof source === 'string'
                //           ? `[z-source]{${source}}`
                //           : `[z-source]{${source.join('\n')}}`
                //     }
                id = match[1];
                tags = new Set(match[2] ? match[2].replace(/^#|#$/g, '').split('#') : []);
                content = match[3] ? match[3] : [];
                if (zettels.ids[id]) {
                    throw new Error(`Zettel id: ${id} already exists at line: ${zettels.ids[id].lineNumber}`);
                }
                // Index tags for fast access
                for (const tag of tags) {
                    if (!zettels.tags[tag]) {
                        zettels.tags[tag] = new Set();
                    }
                    zettels.tags[tag].add(id);
                }
                // Index zettels for fast access
                zettels.ids[id] = {
                    lineNumber,
                    tags,
                    content,
                };
            }
        }
        catch (e_1_1) { e_1 = { error: e_1_1 }; }
        finally {
            try {
                if (lines_1_1 && !lines_1_1.done && (_a = lines_1.return)) yield _a.call(lines_1);
            }
            finally { if (e_1) throw e_1.error; }
        }
        return zettels;
    });
}
exports.indexZettels = indexZettels;
function populateHub(lines, zettels, notesDir) {
    var lines_2, lines_2_1;
    var e_2, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const newLines = [];
        newLines.push('[[toc]]');
        try {
            for (lines_2 = tslib_1.__asyncValues(lines); lines_2_1 = yield lines_2.next(), !lines_2_1.done;) {
                let line = lines_2_1.value;
                if (!(0, query_1.isQuery)(line)) {
                    // Replace local links with absolute link which server knows how to handle
                    line = line.replace('](./resources/', `](/resources/`);
                    newLines.push(line);
                    continue;
                }
                // Fetch zettels and add them to the hub
                const query = (0, query_1.parseQuery)(line);
                const results = (0, query_1.fetchQuery)(query, zettels);
                // Populate file with query responses
                const resultZettels = results.map((id) => zettels.ids[id]);
                for (const zettel of resultZettels) {
                    if (Array.isArray(zettel.content)) {
                        newLines.push(`${' '.repeat(query.indent)}- ${zettel.content[0]}`);
                        for (const line of zettel.content.slice(1)) {
                            newLines.push(`${' '.repeat(query.indent)}${line}`);
                        }
                    }
                    else {
                        newLines.push(`${' '.repeat(query.indent)}- ${zettel.content}`);
                    }
                }
            }
        }
        catch (e_2_1) { e_2 = { error: e_2_1 }; }
        finally {
            try {
                if (lines_2_1 && !lines_2_1.done && (_a = lines_2.return)) yield _a.call(lines_2);
            }
            finally { if (e_2) throw e_2.error; }
        }
        return newLines;
    });
}
exports.populateHub = populateHub;
function indexCategories(categoriesFileName) {
    var e_3, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const categoriesRE = /^\s*- ([^#]*) (#.*#)$/;
        const lines = (0, helpers_1.readLines)(categoriesFileName);
        let match;
        let category;
        let categories;
        const graph = {};
        const sortedGraph = {};
        try {
            for (var lines_3 = tslib_1.__asyncValues(lines), lines_3_1; lines_3_1 = yield lines_3.next(), !lines_3_1.done;) {
                const line = lines_3_1.value;
                match = line.match(categoriesRE);
                if (!match) {
                    continue;
                }
                category = match[1];
                categories = match[2].replace(/^#|#$/g, '').split('#');
                if (graph[category]) {
                    for (const c of categories) {
                        graph[category].add(c);
                    }
                }
                else {
                    graph[category] = new Set(categories);
                }
            }
        }
        catch (e_3_1) { e_3 = { error: e_3_1 }; }
        finally {
            try {
                if (lines_3_1 && !lines_3_1.done && (_a = lines_3.return)) yield _a.call(lines_3);
            }
            finally { if (e_3) throw e_3.error; }
        }
        // Sort categories
        for (const category in graph) {
            sortedGraph[category] = Array.from(graph[category]).sort();
        }
        return sortedGraph;
    });
}
exports.indexCategories = indexCategories;
const articleRE = /.zortex/;
const tagRE = /^([A-Z][a-z]*)?(@+)(.*)$/;
function indexArticles(projectDir) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        let match;
        const articles = { names: new Set(), tags: new Set(), ids: {} };
        yield Promise.all(fs.readdirSync(projectDir).map((file) => tslib_1.__awaiter(this, void 0, void 0, function* () {
            var e_4, _a;
            if (!articleRE.test(file)) {
                return;
            }
            try {
                for (var _b = tslib_1.__asyncValues((0, helpers_1.readLines)(path.join(projectDir, file))), _c; _c = yield _b.next(), !_c.done;) {
                    const line = _c.value;
                    match = line.match(tagRE);
                    if (line.length === 0) {
                        continue;
                    }
                    if (!match) {
                        return;
                    }
                    if (!articles.ids[file]) {
                        articles.ids[file] = { name: null, tags: [] };
                    }
                    if (match[2].length === 1) {
                        articles.tags.add(match[3]);
                        articles.ids[file].tags.push(match[3]);
                    }
                    else {
                        articles.names.add(match[3]);
                        articles.ids[file].name = match[3];
                    }
                }
            }
            catch (e_4_1) { e_4 = { error: e_4_1 }; }
            finally {
                try {
                    if (_c && !_c.done && (_a = _b.return)) yield _a.call(_b);
                }
                finally { if (e_4) throw e_4.error; }
            }
        })));
        return articles;
    });
}
exports.indexArticles = indexArticles;
