"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.fetchQuery = exports.parseQuery = exports.matchQuery = void 0;
// % #asdf#asdfa#
const queryRE = /^(\s*)%\s*(.*)$/;
function matchQuery(line) {
    const match = line.match(queryRE);
    if (!match) {
        return null;
    }
    const indent = match[1].length;
    const query = parseQuery(match[2]);
    return [indent, query];
}
exports.matchQuery = matchQuery;
// TODO: make query more sophisticated
function parseQuery(query) {
    let tags;
    query = query.trim();
    tags = query.replace(/^#|#$/g, '').split('#');
    return {
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
