/// <reference types="node" />
import { Interface } from 'readline';
export declare type Lines = Interface | string[];
export declare type Structures = {
    [name: string]: {
        root: Structure;
        tags: string[];
        structures: Structure[];
    };
};
export interface Structure {
    text: string;
    slug: string;
    indent: number;
    isLink: boolean;
}
export interface Query {
    indent: number;
    tags: string[];
}
export interface Articles {
    names: Set<string>;
    tags: Set<string>;
    ids: {
        [id: string]: {
            name: string;
            tags: string[];
        };
    };
}
export interface Zettels {
    tags: {
        [tag: string]: Set<string>;
    };
    ids: {
        [id: string]: {
            tags: Set<string>;
            content: string | string[];
            lineNumber: number;
        };
    };
}
export interface Env {
    structures: boolean;
    onlyTags: boolean;
    relatedTags: boolean;
    repl: boolean;
    missingTags: boolean;
    command?: string;
    extension: string;
    zettelsFile: string;
    structuresFile: string;
    noteFile: string;
    projectDir: string;
    zettels: Zettels;
    categoriesGraph: {
        [key: string]: string[];
    };
}
