import { Query, Zettels } from './types';
export declare function matchQuery(line: string): [number, Query];
export declare function parseQuery(query: string): Query;
export declare function fetchQuery(query: Query, zettels: Zettels): string[];
