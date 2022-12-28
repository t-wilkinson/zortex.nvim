"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.repl = exports.executeCommand = void 0;
const tslib_1 = require("tslib");
const readline = tslib_1.__importStar(require("readline"));
const child_process = tslib_1.__importStar(require("child_process"));
const fs = tslib_1.__importStar(require("fs"));
const zettel_1 = require("./zettel");
const query_1 = require("./query");
const helpers_1 = require("./helpers");
function executeCommand(input, loop, env, rl) {
    var e_1, _a;
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const [command, ...args] = input.split(' ');
        if (command === 'help') {
            console.log('REPL for zettels');
            console.log();
            console.log('exit, quit - exit the program');
            console.log('copy - copy the previous query results to clipboard');
            return loop();
        }
        if (command === 'exit' || command === 'quit') {
            return rl.close();
        }
        if (command === 'categories') {
            let res = [
                'digraph categories {',
                '  rankdir=LR;',
                '  graph [pad="1", mindist="0.1", nodesep="0.03", ranksep="0.1"];',
                '  node [shape=none, fontsize=10];',
            ];
            for (const [node, children] of Object.entries(env.categoriesGraph)) {
                res.push(`  "${(0, helpers_1.toSpacecase)(node)}" -> { ${children
                    .map((category) => `"${(0, helpers_1.toSpacecase)(category)}"`)
                    .join(' ')} }`);
            }
            res.push('}');
            const dotProcess = child_process.spawn('dot', ['-Tsvg']);
            let svg = '';
            dotProcess.stdin.write(res.join('\n'));
            dotProcess.stdout.on('data', (data) => {
                svg += data;
            });
            dotProcess.stdin.end();
            dotProcess.on('close', () => {
                const fehProcess = child_process.spawn('feh', ['--zoom', '50%', '-']);
                fehProcess.stdin.write(svg);
                fehProcess.stdin.end();
            });
            return loop();
        }
        // TODO: markdown list hierarchy to graph
        if (command === 'hierarchy') {
            return loop();
        }
        if (command === 'tags') {
            const articles = yield (0, zettel_1.indexArticles)(env.projectDir);
            console.log([...articles.tags].join('\n'));
        }
        // Create links to articles in "structure.zettel"
        if (command === 'structure') {
            const articles = yield (0, zettel_1.indexArticles)(env.projectDir);
            const lineRE = /^(\s*)(-|\*) ([^[].*[^\]])( #.*#)?$/;
            const lines = (0, helpers_1.readLines)(env.structuresFile);
            const content = [];
            try {
                for (var lines_1 = tslib_1.__asyncValues(lines), lines_1_1; lines_1_1 = yield lines_1.next(), !lines_1_1.done;) {
                    const line = lines_1_1.value;
                    const match = line.match(lineRE);
                    if (!match) {
                        content.push(line);
                        continue;
                    }
                    const spaces = match[1];
                    const bullet = match[2];
                    const titles = match[3].split(' == ');
                    if (titles.some((t) => articles.names.has(t))) {
                        for (const title of titles) {
                            content.push(`${spaces}${bullet} [${title}]`);
                        }
                    }
                    else {
                        content.push(line);
                    }
                }
            }
            catch (e_1_1) { e_1 = { error: e_1_1 }; }
            finally {
                try {
                    if (lines_1_1 && !lines_1_1.done && (_a = lines_1.return)) yield _a.call(lines_1);
                }
                finally { if (e_1) throw e_1.error; }
            }
            // @ts-ignore
            fs.writeFileSync(env.structuresFile, content.join('\n'), (err) => {
                if (err) {
                    console.log(err);
                }
                console.log('Success');
            });
        }
        // TODO: easy way to create timelines
        if (command === 'timeline') {
            return loop();
        }
        if (command === 'circle') {
            let res = `graph circle {
    layout="circo"
    graph [root=A, mindist=0.25]
    node [width=0.5, fixedsize=true, shape=circle]
    edge [style=invis]
    ${args.join(', ')} [style=filled, fillcolor=purple, fontcolor=white]
    A  -- A♭
    A♭ -- B
    B  -- C♭
    C♭ -- C
    C  -- D♭
    D♭ -- D
    D  -- E
    E  -- F
    F  -- F♭
    F♭ -- G
    G  -- G♭
    G♭ -- A
}`;
            console.log(res);
            return loop();
        }
        if (command === 'graphvis') {
            let res = [];
            res.push('graph G {');
            res.push('  layout=twopi; graph [ranksep=1.5];');
            res.push('  node [style="" penwidth=0 fillcolor="#f0f0ff00" fontcolor=indigo]');
            res.push('  edge [penwidth=1 color="#f0f0ff"]');
            res.push(`  node [fontsize=35] ${args.join(' ')}`);
            for (const arg of args) {
                res.push('  node [fontsize=20]');
                const tags_1 = (0, helpers_1.relatedTags)(env.zettels, arg);
                // First level
                res.push(`  ${arg} [URL="/${arg}"]`);
                res.push(`  ${arg} -- {`);
                for (const tag of tags_1) {
                    res.push(`    "${tag}"`);
                }
                res.push(`  }`);
                // Second level
                res.push('');
                res.push('  node [fontsize=12]');
                for (const tag of tags_1) {
                    const tags_2 = (0, helpers_1.relatedTags)(env.zettels, tag);
                    res.push(`  ${tag} [URL="/${tag}"]`);
                    res.push(`  ${tag} -- {`);
                    for (const tag2 of tags_2) {
                        if (tag2 === arg) {
                            continue;
                        }
                        res.push(`    "${tag2}"`);
                    }
                    res.push(`  }`);
                }
            }
            res.push('}');
            console.log(res.join('\n'));
            return loop();
        }
        if (command === 'related-tags') {
            for (const arg of args) {
                const related = (0, helpers_1.relatedTags)(env.zettels, arg).sort();
                console.log(`\x1b[36m${arg}: \x1b[0m${related.join(' ')}`);
            }
            return loop();
        }
        // Copy previous query results to clipboard
        // if (command === 'copy') {
        //   const data = ids.map((id: string) => {
        //     const zettel = env.zettels.ids[id]
        //     return toZettel(id, zettel.tags, zettel.content)
        //   }).join('\n')
        //   const proc = require('child_process').exec('xclip -in -selection clipboard')
        //   proc.stdin.write(data)
        //   proc.stdin.end()
        //   return loop()
        // }
        // Parse and run query
        const query = (0, query_1.parseQuery)(`${command} ${args.join(' ')}`);
        (0, zettel_1.showZettels)((0, query_1.fetchQuery)(query, env.zettels), env.zettels);
        loop();
    });
}
exports.executeCommand = executeCommand;
function replLoop(env, rl, ids) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        function loop() {
            return replLoop(env, rl, ids);
            // indexCategories(env.categoriesFile).then((graph) => {
            //   env.categoriesGraph = graph
            //   return replLoop(env, rl, ids)
            // })
        }
        rl.question('\x1b[35m% \x1b[36m', (input) => tslib_1.__awaiter(this, void 0, void 0, function* () {
            yield executeCommand(input, loop, env, rl);
        }));
    });
}
function repl(env) {
    return tslib_1.__awaiter(this, void 0, void 0, function* () {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });
        // env.categoriesGraph = await indexCategories(env.categoriesFile)
        return replLoop(env, rl, []);
    });
}
exports.repl = repl;
