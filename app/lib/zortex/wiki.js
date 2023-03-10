"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.findArticle = exports.searchArticles = exports.matchArticle = exports.getArticles = exports.parseArticleTitle = exports.slugifyArticleName = exports.compareArticleNames = exports.compareArticle = exports.compareArticleSlugs = void 0;
const tslib_1 = require("tslib");
const fs = tslib_1.__importStar(require("fs"));
const path = tslib_1.__importStar(require("path"));
const zettel_1 = require("./zettel");
const helpers_1 = require("./helpers");
function compareArticleSlugs(slug1, slug2) {
    return slug1.toLowerCase() === slug2.toLowerCase();
}
exports.compareArticleSlugs = compareArticleSlugs;
function compareArticle(name, slug) {
    return compareArticleSlugs(slugifyArticleName(name), slug);
}
exports.compareArticle = compareArticle;
function compareArticleNames(name1, name2) {
    return compareArticleSlugs(slugifyArticleName(name1), slugifyArticleName(name2));
}
exports.compareArticleNames = compareArticleNames;
function slugifyArticleName(articleName) {
    return articleName.replace(/ /g, '_');
}
exports.slugifyArticleName = slugifyArticleName;
function parseArticleTitle(titleLine) {
    let title = titleLine.replace(/^@+/, '');
    // if article title is a link, extract the name
    // [name](link)
    if (title.charAt(0) === '[') {
        const match = title.match(/^\[([^\]]+)]/); // \([^)]+\)$/)
        if (match) {
            title = match[1];
        }
    }
    return {
        title,
        slug: slugifyArticleName(title),
    };
}
exports.parseArticleTitle = parseArticleTitle;
function getArticles(notesDir) {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const articles = {};
        // get article names
        const fileNames = fs
            .readdirSync(notesDir, { withFileTypes: true })
            .filter((item) => !item.isDirectory())
            .map((item) => item.name);
        try {
            for (var fileNames_1 = tslib_1.__asyncValues(fileNames), fileNames_1_1; fileNames_1_1 = yield fileNames_1.next(), !fileNames_1_1.done;) {
                const fileName = fileNames_1_1.value;
                const article = yield (0, helpers_1.getArticleTitle)(path.join(notesDir, fileName));
                articles[article.slug] = {
                    title: article.title,
                    fileName,
                    slug: article.slug,
                };
            }
        }
        catch (e_1_1) { e_1 = { error: e_1_1 }; }
        finally {
            try {
                if (fileNames_1_1 && !fileNames_1_1.done && (_a = fileNames_1.return)) yield _a.call(fileNames_1);
            }
            finally { if (e_1) throw e_1.error; }
        }
        return articles;
    });
}
exports.getArticles = getArticles;
function matchArticle(notesDir, articleName, articles) {
    const slug = slugifyArticleName(articleName);
    const article = articles[slug];
    if (!article) {
        return null;
    }
    const content = fs
        .readFileSync(path.join(notesDir, article.fileName))
        .toString()
        .split('\n');
    return Object.assign(Object.assign({}, article), { content });
}
exports.matchArticle = matchArticle;
function searchArticles(articles, search) {
    if (search === '') {
        return [];
    }
    const terms = slugifyArticleName(search)
        .toLowerCase()
        .split(/[ _-]/)
        .filter((x) => x);
    const matches = Object.values(articles).reduce((acc, article) => {
        const slug = slugifyArticleName(article.title).toLowerCase();
        if (terms.every((term) => slug.includes(term))) {
            acc.push(article);
        }
        return acc;
    }, []);
    return matches.sort((a, b) => (a.slug < b.slug) ? -1 : (a.slug > b.slug) ? 1 : 0);
}
exports.searchArticles = searchArticles;
function findArticle(notesDir, extension, articleName, articles) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const article = matchArticle(notesDir, articleName, articles);
        if (!article) {
            return null;
        }
        const zettels = yield (0, zettel_1.indexZettels)(path.join(notesDir, 'zettels' + extension));
        const content = yield (0, zettel_1.populateHub)(article.content, zettels, notesDir);
        return Object.assign(Object.assign({ articleName }, article), { content });
    });
}
exports.findArticle = findArticle;
