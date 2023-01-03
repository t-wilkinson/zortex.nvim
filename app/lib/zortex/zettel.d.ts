import { Articles, Zettels, Lines } from './types';
export declare function newZettelId(): string;
export declare function toZettel(id: string, tags: string[], content: string | string[]): string;
export declare function showZettels(ids: string[], zettels: Zettels): void;
export declare function indexZettels(zettelsFile: string): Promise<Zettels>;
export declare function populateHub(lines: Lines, zettels: Zettels, notesDir: string): Promise<string[]>;
export declare function indexCategories(categoriesFileName: string): Promise<{
    [key: string]: string[];
}>;
export declare function indexArticles(projectDir: string): Promise<Articles>;
