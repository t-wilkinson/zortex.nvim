import { Env } from './types';
export declare function executeCommand(input: string, loop: any, env: Env, rl: any): Promise<any>;
export declare function repl(env: Env): Promise<void>;
