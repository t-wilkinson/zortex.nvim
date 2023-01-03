"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.run = void 0;
const tslib_1 = require("tslib");
const path = tslib_1.__importStar(require("path"));
const zettel_1 = require("./zettel");
const helpers_1 = require("./helpers");
const repl_1 = require("./repl");
const structures_1 = require("./structures");
function parseArgs(args) {
    const env = {
        onlyTags: false,
        relatedTags: false,
        repl: false,
        missingTags: false,
        structures: false,
        command: null,
        extension: '.zortex',
        zettelsFile: 'zettels.zortex',
        // categoriesFile: 'categories.zortex',
        structuresFile: 'structure.zortex',
        noteFile: '',
        projectDir: `${process.env.HOME}/zortex`,
        zettels: null,
        categoriesGraph: null,
    };
    let i = 0;
    function nextArg() {
        i++;
        return args[i];
    }
    while (i < args.length) {
        switch (args[i]) {
            case '--command':
            case '-c':
                env.command = nextArg();
                break;
            // case '--categories':
            // env.categoriesFile = nextArg()
            // break
            case '--zettels':
            case '-z':
                env.zettelsFile = nextArg();
                break;
            case '--note':
            case '-n':
                env.noteFile = nextArg();
                break;
            case '--project-dir':
            case '-p':
                env.projectDir = nextArg();
                break;
            case '--structures':
                env.structures = true;
                break;
            case '--missing-tags':
                env.missingTags = true;
                break;
            case '--repl':
                env.repl = true;
                break;
            case '--related-tags':
                env.relatedTags = true;
                break;
            case '--only-tags':
                env.onlyTags = true;
                break;
            default:
                throw new Error(`Unknown argument: ${args[i]}`);
        }
        i++;
    }
    return env;
}
function setupEnv(env) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        function resolveFile(key) {
            if (env[key]) {
                env[key] = path.resolve(env.projectDir, env[key]);
            }
        }
        resolveFile('structuresFile');
        // resolveFile('categoriesFile')
        resolveFile('zettelsFile');
        resolveFile('noteFile');
        if (env.zettelsFile) {
            env.zettels = yield (0, zettel_1.indexZettels)(env.zettelsFile);
        }
        return env;
    });
}
function run() {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const env = yield setupEnv(parseArgs(process.argv.slice(2)));
        if (env.command) {
            // env.categoriesGraph = await indexCategories(env.categoriesFile)
            return (0, repl_1.executeCommand)(env.command, () => { }, env, null);
        }
        // REPL
        if (env.repl) {
            return (0, repl_1.repl)(env);
        }
        // Show related tags
        if (env.relatedTags) {
            return (0, helpers_1.inspect)((0, helpers_1.allRelatedTags)(env.zettels));
        }
        if (env.missingTags) {
            const hubTags = new Set();
            const lines = (0, helpers_1.readLines)(env.noteFile);
            const tagRE = /- ([a-z0-9][a-z0-9=-]*)/;
            const zettelIdRE = /z:[0-9.]+/;
            try {
                for (var lines_1 = tslib_1.__asyncValues(lines), lines_1_1; lines_1_1 = yield lines_1.next(), !lines_1_1.done;) {
                    const line = lines_1_1.value;
                    const match = line.match(tagRE);
                    if (!match) {
                        continue;
                    }
                    hubTags.add(match[1]);
                }
            }
            catch (e_1_1) { e_1 = { error: e_1_1 }; }
            finally {
                try {
                    if (lines_1_1 && !lines_1_1.done && (_a = lines_1.return)) yield _a.call(lines_1);
                }
                finally { if (e_1) throw e_1.error; }
            }
            const missingTags = [...Object.keys(env.zettels.tags)]
                .filter((tag) => {
                return !hubTags.has(tag) && !zettelIdRE.test(tag);
            })
                .sort();
            console.log(missingTags);
            return;
        }
        // Show tag count of all zettels
        if (env.onlyTags) {
            let tags;
            tags = Object.entries(env.zettels.tags).reduce((acc, [tag, zettels]) => {
                acc[tag] = zettels.size;
                return acc;
            }, {});
            tags = Object.fromEntries(Object.entries(tags).sort(([, a], [, b]) => a - b));
            for (const [zettel, count] of Object.entries(tags)) {
                console.log(`\x1b[36m${zettel}: \x1b[0m${count}`);
            }
            return;
        }
        if (env.structures) {
            const structures = yield (0, structures_1.getArticleStructures)(env.projectDir, env.extension);
            (0, helpers_1.inspect)(structures);
            return;
        }
        // Show indexed zettels
        if (!env.noteFile) {
            console.log(env.zettels);
            return;
        }
        // Populate hub with zettels
        if (env.noteFile && env.zettelsFile) {
            const lines = (0, helpers_1.readLines)(env.noteFile);
            const populatedHub = yield (0, zettel_1.populateHub)(lines, env.zettels, env.projectDir);
            (0, helpers_1.inspect)(populatedHub);
            return;
        }
    });
}
exports.run = run;
if (!module.parent) {
    ;
    (() => tslib_1.__awaiter(void 0, void 0, void 0, function* () {
        try {
            yield run();
        }
        catch (e) {
            console.error(e);
        }
    }))();
}
