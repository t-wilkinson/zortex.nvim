import { Attach, NeovimClient } from '@chemzqm/neovim';
interface IApp {
    refreshPage: (param: {
        data: any;
    }) => void;
    openBrowser: (params: {}) => void;
}
export interface IPlugin {
    init: (app: IApp) => void;
    nvim: NeovimClient;
}
export default function (options: Attach): IPlugin;
export {};
