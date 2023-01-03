"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getArticleTitle = exports.getArticleFilepath = exports.toSpacecase = exports.allRelatedTags = exports.relatedTags = exports.readLines = exports.getFirstLine = exports.inspect = void 0;
const tslib_1 = require("tslib");
const util = tslib_1.__importStar(require("util"));
const fs = tslib_1.__importStar(require("fs"));
const path = tslib_1.__importStar(require("path"));
const readline = tslib_1.__importStar(require("readline"));
const wiki_1 = require("./wiki");
function inspect(x) {
    console.log(util.inspect(x, {
        showHidden: false,
        depth: null,
        colors: true,
        maxArrayLength: null,
        breakLength: 3,
        compact: 8,
    }));
}
exports.inspect = inspect;
function getFirstLine(pathToFile) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const readable = fs.createReadStream(pathToFile);
        const reader = readline.createInterface({ input: readable });
        const firstLine = yield new Promise((resolve) => {
            reader.on('line', (line) => {
                reader.close();
                resolve(line);
            });
        });
        readable.close();
        return firstLine;
    });
}
exports.getFirstLine = getFirstLine;
function readLines(filename) {
    const fileStream = fs.createReadStream(filename);
    const lines = readline.createInterface({
        input: fileStream,
        crlfDelay: Infinity,
    });
    return lines;
}
exports.readLines = readLines;
function relatedTags(zettels, tag) {
    var _a;
    const relatedTags = new Set();
    (_a = zettels.tags[tag]) === null || _a === void 0 ? void 0 : _a.forEach((id) => {
        const zettel = zettels.ids[id];
        zettel.tags.forEach((t) => {
            if (t !== tag) {
                relatedTags.add(t);
            }
        });
    });
    return [...relatedTags];
}
exports.relatedTags = relatedTags;
/**
 * Return which tags each tag is associated with
 */
function allRelatedTags(zettels) {
    let tags = Object.keys(zettels.tags).reduce((acc, tag) => {
        acc[tag] = new Set();
        return acc;
    }, {});
    // For each tag, add all tags that are associated with it
    for (const zettel of Object.values(zettels.ids)) {
        for (const tag of zettel.tags) {
            zettel.tags.forEach(tags[tag].add, tags[tag]);
        }
    }
    // Convert tags to array
    for (const tag of Object.keys(tags)) {
        tags[tag] = [...tags[tag]];
    }
    return tags;
}
exports.allRelatedTags = allRelatedTags;
function toSpacecase(str) {
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/-/g, ' ');
}
exports.toSpacecase = toSpacecase;
function getArticleFilepath(notesDir, articleName) {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const articleSlug = (0, wiki_1.slugifyArticleName)(articleName);
        // get article files
        const fileNames = fs
            .readdirSync(notesDir, { withFileTypes: true })
            .filter((item) => !item.isDirectory())
            .map((item) => item.name);
        try {
            for (var fileNames_1 = tslib_1.__asyncValues(fileNames), fileNames_1_1; fileNames_1_1 = yield fileNames_1.next(), !fileNames_1_1.done;) {
                const fileName = fileNames_1_1.value;
                const filepath = path.join(notesDir, fileName);
                const line = yield getFirstLine(filepath);
                const { slug } = (0, wiki_1.parseArticleTitle)(line);
                if ((0, wiki_1.compareArticleSlugs)(slug, articleSlug)) {
                    return filepath;
                }
            }
        }
        catch (e_1_1) { e_1 = { error: e_1_1 }; }
        finally {
            try {
                if (fileNames_1_1 && !fileNames_1_1.done && (_a = fileNames_1.return)) yield _a.call(fileNames_1);
            }
            finally { if (e_1) throw e_1.error; }
        }
    });
}
exports.getArticleFilepath = getArticleFilepath;
function getArticleTitle(filepath) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const line = yield getFirstLine(filepath);
        return (0, wiki_1.parseArticleTitle)(line);
    });
}
exports.getArticleTitle = getArticleTitle;
