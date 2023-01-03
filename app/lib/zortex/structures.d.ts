import { Structures } from './types';
export declare function getArticleStructures(notesDir: string, extension: string): Promise<Structures>;
export declare function getMatchingStructures(articleName: string, structures: Structures): Structures[keyof Structures][];
