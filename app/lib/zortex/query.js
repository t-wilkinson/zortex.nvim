"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.fetchQuery = exports.parseQuery = exports.isQuery = void 0;
// % #asdf#asdfa#
const queryRE = /^(\s*)%\s*#(.*)#$/;
const isQueryRE = /^(\s*)%\s/;
function isQuery(line) {
    return isQueryRE.test(line);
}
exports.isQuery = isQuery;
function parseQuery(queryString) {
    const match = queryString.match(queryRE);
    if (!match) {
        return null;
    }
    const indent = match[1].length;
    const query = match[2].trim();
    let tags;
    tags = query.split('#').filter((v) => v);
    return {
        indent,
        tags,
    };
}
exports.parseQuery = parseQuery;
function fetchQuery(query, zettels) {
    // Remove tags that aren't found in zettels
    const queryTags = query.tags.filter((tag) => zettels.tags[tag]);
    if (queryTags.length === 0) {
        return [];
    }
    // Get the tag with smallest number of zettels
    let smallestTag = queryTags[0];
    for (const tag of queryTags) {
        if (zettels.tags[tag].size < zettels.tags[smallestTag].size) {
            smallestTag = tag;
        }
    }
    // Keep only zettels which have all tags
    const zettelsWithTags = [...zettels.tags[smallestTag]].filter((id) => {
        return queryTags.every((tag) => zettels.tags[tag].has(id));
    });
    return zettelsWithTags;
}
exports.fetchQuery = fetchQuery;
