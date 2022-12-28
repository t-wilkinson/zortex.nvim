import { LocalRequest, Routes } from './server';
export declare const onWebsocketConnection: (logger: any, client: any, clients: any, plugin: any) => Promise<void>;
declare const _default: {
    routes: Routes<LocalRequest>;
};
export default _default;
