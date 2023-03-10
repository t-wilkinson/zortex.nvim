export interface Article {
    title: string;
    fileName: string;
    slug: string;
}
export declare type Articles = {
    [slug: string]: Article;
};
export declare function compareArticleSlugs(slug1: string, slug2: string): boolean;
export declare function compareArticle(name: string, slug: string): boolean;
export declare function compareArticleNames(name1: string, name2: string): boolean;
export declare function slugifyArticleName(articleName: string): string;
export declare function parseArticleTitle(titleLine: string): {
    title: string;
    slug: string;
};
export declare function getArticles(notesDir: string): Promise<Articles>;
export declare function matchArticle(notesDir: string, articleName: string, articles: Articles): {
    content: string[];
    title: string;
    fileName: string;
    slug: string;
};
export declare function searchArticles(articles: Articles, search: string): any[];
export declare function findArticle(notesDir: string, extension: string, articleName: string, articles: Articles): Promise<{
    content: string[];
    title: string;
    fileName: string;
    slug: string;
    articleName: string;
}>;
