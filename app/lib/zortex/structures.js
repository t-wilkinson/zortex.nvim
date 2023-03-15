"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getMatchingStructures = exports.getArticleStructures = void 0;
const tslib_1 = require("tslib");
const path = tslib_1.__importStar(require("path"));
const helpers_1 = require("./helpers");
const wiki_1 = require("./wiki");
/*
 * - how to make level of nesting equal to number of each item in array?
 * - information related to root structures should not be including in recusion
 * - should be efficient for items at same nesting level
 *
 * - should each call handle one level of nesting
 */
/*
const lineRE = /^(\s*)(\*|-) (\[)?([^\]]*?)]?( #.*#)?$/
export async function getArticleStructures(notesDir: string, extension: string): Promise<Structures> {
  const structuresFilepath = path.join(notesDir, 'structure' + extension)
  const lines_ = readLines(structuresFilepath)
  let m: RegExpMatchArray
  const structures: Structures = {}

  let currentLine = 0
  let line: string
  let rootIndent = null

  const lines = []
  for await (const line of lines_) {
    lines.push(line)
  }

  const buildStructures = async (
    currentIndent: number,
    currentStructure: Structure
  ) => {
    line = lines[currentLine]
    currentLine++

    m = line.match(lineRE)
    if (!m) {
      return
    }

    const indent = m[1].length
    const item = m[2]
    const isLink = !!m[3]
    const text = m[4]

    const structure: Structure = {
      text,
      slug: isLink ? slugifyArticleName(text) : null,
      isLink,
      structures: await buildStructures(indent, []),
    }
    currentStructures.push(structure)

    if (item === '*') {
      const tags = m[5] || ''
      rootIndent = indent
      structures[text] = {
        tags: tags.trim().split('#').filter(v => v),
        root: structure,
      }
    }
  }

  await buildStructures(null, [])
  return structures
}
*/
const lineRE = /^(\s*)(\*|-) (\[)?([^\]]*?)]?( #.*#)?$/;
function getArticleStructures(notesDir, extension) {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const structuresFilepath = path.join(notesDir, 'structure' + extension);
        const lines = (0, helpers_1.readLines)(structuresFilepath);
        let m;
        let rootText = null;
        let rootIndent = null;
        const structures = {};
        try {
            for (var lines_1 = tslib_1.__asyncValues(lines), lines_1_1; lines_1_1 = yield lines_1.next(), !lines_1_1.done;) {
                const line = lines_1_1.value;
                m = line.match(lineRE);
                if (!m) {
                    continue;
                }
                const indent = m[1].length;
                const item = m[2];
                const isLink = !!m[3];
                const text = m[4];
                const tags = m[5] || '';
                const slug = isLink ? (0, wiki_1.slugifyArticleName)(text) : null;
                // Lines with '*' bullet are considered root structures
                if (item === '*') {
                    rootText = text;
                    rootIndent = indent;
                    structures[text] = {
                        root: {
                            text,
                            slug,
                            indent,
                            isLink,
                        },
                        tags: tags.trim().split('#').filter(v => v),
                        structures: [],
                    };
                }
                // If line is at the indent of the root, start looking for next root
                if (item === '-' && indent <= rootIndent) {
                    rootIndent = null;
                    rootText = null;
                    continue;
                }
                if (rootText && item === '-' && indent > rootIndent) {
                    structures[rootText].structures.push({
                        text,
                        slug,
                        isLink,
                        indent: indent - rootIndent,
                    });
                }
            }
        }
        catch (e_1_1) { e_1 = { error: e_1_1 }; }
        finally {
            try {
                if (lines_1_1 && !lines_1_1.done && (_a = lines_1.return)) yield _a.call(lines_1);
            }
            finally { if (e_1) throw e_1.error; }
        }
        return structures;
    });
}
exports.getArticleStructures = getArticleStructures;
function getMatchingStructures(articleName, structures) {
    const matchingBranches = [];
    const slug = (0, wiki_1.slugifyArticleName)(articleName);
    const articleTag = slug.replace(/_/g, '-').toLowerCase();
    next_branch: for (const branch of Object.values(structures)) {
        if ((0, wiki_1.compareArticleNames)(branch.root.text, articleName)) {
            matchingBranches.push(branch);
            continue next_branch;
        }
        if (branch.tags.some((tag) => tag === articleTag)) {
            matchingBranches.push(branch);
            continue next_branch;
        }
        for (const structure of branch.structures) {
            if ((0, wiki_1.compareArticle)(structure.text, slug)) {
                matchingBranches.push(branch);
                continue next_branch;
            }
        }
    }
    return matchingBranches;
}
exports.getMatchingStructures = getMatchingStructures;
