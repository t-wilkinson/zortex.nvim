/// <reference types="node" />
import * as readline from 'readline';
import { Zettels } from './types';
export declare function inspect(x: any): void;
export declare function getFirstLine(pathToFile: string): Promise<string>;
export declare function readLines(filename: string): readline.Interface;
export declare function relatedTags(zettels: Zettels, tag: string): string[];
/**
 * Return which tags each tag is associated with
 */
export declare function allRelatedTags(zettels: Zettels): {};
export declare function toSpacecase(str: string): string;
export declare function getArticleFilepath(notesDir: string, articleName: string): Promise<string>;
export declare function getArticleTitle(filepath: any): Promise<{
    title: string;
    slug: string;
}>;
