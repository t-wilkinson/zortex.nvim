/// <reference types="node" />
import { Logger } from 'log4js';
import { IPlugin } from '../attach';
import { IncomingMessage, ServerResponse } from 'http';
import { Articles } from '../zortex/wiki';
export declare type RemoteRequest = IncomingMessage & {
    asPath: string;
    extension: string;
    notesDir: string;
    articles: Articles;
};
export declare type LocalRequest = IncomingMessage & {
    plugin: IPlugin;
    logger: Logger;
    bufnr: string;
    asPath: string;
    mkcss: string;
    hicss: string;
    notesDir: string;
    extension: string;
    articles: Articles;
};
export declare type ServerRequest = RemoteRequest | LocalRequest;
export declare type Route<Request> = (req: Request, res: ServerResponse, next: () => Route<Request>) => any;
export declare type Routes<Request> = Route<Request>[];
export declare function listener<Request>(req: Request, res: ServerResponse, routes: Routes<Request>): void;
export declare const staticRoutes: Routes<LocalRequest>;
