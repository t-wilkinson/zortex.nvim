/// <reference types="node" />
import * as readline from 'readline';
import { Articles, Zettels } from './types';
export declare function newZettelId(): string;
export declare function toZettel(id: string, tags: string[], content: string | string[]): string;
export declare function showZettels(ids: string[], zettels: Zettels): void;
export declare function indexZettels(zettelsFile: string): Promise<Zettels>;
export declare function populateHub(lines: readline.Interface | string[], zettels: Zettels): Promise<any[]>;
export declare function indexCategories(categoriesFile: string): Promise<{
    [key: string]: string[];
}>;
export declare function indexArticles(projectDir: string): Promise<Articles>;
