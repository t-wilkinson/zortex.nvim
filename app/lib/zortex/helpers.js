"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.toSpacecase = exports.allRelatedTags = exports.relatedTags = exports.readLines = exports.getFirstLine = exports.inspect = void 0;
const tslib_1 = require("tslib");
const util = tslib_1.__importStar(require("util"));
const fs = tslib_1.__importStar(require("fs"));
const readline = tslib_1.__importStar(require("readline"));
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
