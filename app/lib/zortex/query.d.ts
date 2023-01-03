import { Query, Zettels } from './types';
export declare function isQuery(line: string): boolean;
export declare function parseQuery(queryString: string): Query;
export declare function fetchQuery(query: Query, zettels: Zettels): string[];
