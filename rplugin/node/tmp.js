const fs = require("fs");
const readline = require("readline");
const open = require("open");
const path = require("path");
const cheerio = require("cheerio");
const fetch = require("node-fetch");
const os = require("os");
const process = require("process");

function readLines(filename) {
  const fileStream = fs.createReadStream(filename);
  const lines = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity,
  });
  return lines;
}

async function readZortexLines(nvim, filePath) {
  const notesDir = await nvim.eval(`g:zortex_notes_dir`);
  return readLines(path.join(notesDir, filePath));
}

async function getFirstLine(pathToFile) {
  const readable = fs.createReadStream(pathToFile);
  const reader = readline.createInterface({ input: readable });
  const line = await new Promise((resolve) => {
    reader.on("line", (line) => {
      reader.close();
      resolve(line);
    });
  });
  readable.close();
  return line;
}

function normalizeArticleName(name) {
  return name.trim().toLowerCase().replace(/\s+/g, "-").replace(/^@+/, "");
}

function articleNamesMatch(n1, n2) {
  return normalizeArticleName(n1) === normalizeArticleName(n2);
}

const articleNameRE = /^@@/;
async function getArticleNames(pathToArticle) {
  const names = [];
  const lines = readLines(pathToArticle);
  for await (const line of lines) {
    if (articleNameRE.test(line)) {
      names.push(line);
      continue;
    }
    break;
  }

  return names;
}

async function getArticlePath(nvim, articleName) {
  // find article matching link name and edit it
  const notesDir = await nvim.eval(`get(g:, "zortex_notes_dir", 0)`);
  for await (const file of fs.readdirSync(notesDir)) {
    const articlePath = path.join(notesDir, file);
    const names = await getArticleNames(articlePath);

    for (const name of names) {
      if (articleNamesMatch(articleName, name)) {
        return articlePath;
      }
    }
  }
}

async function openArticle(nvim, articleName) {
  const filePath = await getArticlePath(nvim, articleName);

  if (filePath) {
    const bufName = await nvim.eval(`bufname()`);

    // Open article in current buffer if its not the Structure article
    if (!bufName.endsWith("structure.zortex")) {
      await nvim.command(`edit ${filePath}`);
      return true;
    }

    const numWindows = await nvim.eval(`winnr("$")`);
    const numCols = await nvim.eval(`&columns`);
    if (numWindows > Math.floor(numCols / 100)) {
      // Move each buffer on the right of the structure article to the window on its right
      const curWinNr = await nvim.eval(`winnr()`);

      for (let i = numWindows; i > curWinNr + 1; i--) {
        const bufNr = await nvim.eval(`winbufnr(${i - 1})`);
        await nvim.command(`${i}wincmd w`);
        await nvim.command(`${bufNr}buffer`);
      }

      await nvim.command(`${curWinNr + 1}wincmd w`);
      await nvim.command(`edit ${filePath}`);
    } else {
      await nvim.command(`vsplit ${filePath}`);
    }

    return true;
  } else {
    return false;
  }
}

// const markdownLinkRE = /\[([^\]]+)\]\(([^\)]+)\)/
const lineRE = /^(\s*)- (.*)$/;
const zortexLineRE = /- (?<tags>#.+# )?(?<text>.*)$/;

const websiteLinkRE = /https?:\/\/[^);}]+/;
const fileLinkRE = /\[([^\]]+)\]\(([^\)]+)\)/;
const fragmentLinkRE = /\|([^|]+)\|/;
const zortexLinkRE = /ref=([^\s;}]+)/;
const articleLinkRE = /\[([^\]]+)\]/;
const filePathRE = /(^|\s)(?<path>[~.]?\/[/\S]+)($|\s)/;
const linkRE = /\[(?<text>[^\]]+)\](\((?<ref>[^\)]+)\))?/;
const headingRE = /^#+ (.*)$/;
const zettelLinkRE = /\[(z:\d{4}\.\d{5}\.\d{5})]/;
const footernoteRE = /\[\^(\d+)]/;

async function extractLink(nvim, line) {
  let match;

  if ((match = line.match(websiteLinkRE))) {
    return {
      line,
      type: "website",
      url: match[0],
    };
  } else if ((match = line.match(fileLinkRE))) {
    return {
      line,
      type: "file",
      name: match[1],
      url: match[2],
    };
  } else if ((match = line.match(zortexLinkRE))) {
    return {
      line,
      type: "zortex-link",
      url: match[1],
    };
  } else if ((match = line.match(zettelLinkRE))) {
    let pos = await nvim.eval(`getcurpos()`);
    let col = Number(pos[2]) - 1;
    const re = new RegExp(zettelLinkRE);

    while ((match = re.exec(line)) != null) {
      // find first match that the cursor is on or before
      if (col <= match[0].length + match.index) {
        break;
      }
    }

    return {
      line,
      type: "zettel-link",
      zettel_id: match[1],
    };
  } else if ((match = line.match(footernoteRE))) {
    let col = Number(await nvim.eval(`getpos(".")[2]`)) - 1;
    const re = new RegExp(footernoteRE);

    while ((match = re.exec(line)) != null) {
      // find first match that the cursor is on or before
      if (col <= match[0].length + match.index) {
        break;
      }
    }

    return {
      line,
      type: "footernote",
      ref: match[1],
    };
  } else if ((match = line.match(fragmentLinkRE))) {
    // get line from cursor to end of line
    let col = Number(await nvim.eval(`getpos(".")[2]`)) - 1;
    const re = new RegExp(fragmentLinkRE);

    while ((match = re.exec(line)) != null) {
      // find first match that the cursor is on or before
      // random |link| |link<cursor>| more |link| random text
      //        ^no match ^match            ^no match
      const link = match[1];
      if (col <= link.length + match.index) {
        break;
      }
    }

    return {
      line,
      type: "fragment-link",
      fragment: link,
    };
  } else if ((match = line.match(articleLinkRE))) {
    return {
      line,
      type: "article",
      name: match[1],
    };
  } else if ((match = line.match(filePathRE))) {
    return {
      line,
      type: "path",
      path: match[2],
    };
  } else if ((match = line.match(lineRE))) {
    return {
      line,
      type: "text",
      indent: match[1].length,
      name: match[2],
    };
  } else if ((match = line.match(headingRE))) {
    return {
      line,
      type: "heading",
      name: match[1],
    };
  } else {
    // get text under visual selection
    const selection = await nvim.eval(
      `getline("'<")[getpos("'<")[2]-1:getpos("'>")[2]-1]`,
    );

    return null;
    // return {
    //   line,
    //   type: 'wikipedia',
    //   name: selection.trim(),
    // }
  }
}

async function openLink(nvim) {
  const line = await nvim.getLine();
  const filename = await nvim.eval(`expand("%:t:r")`);

  // get article name
  const link = await extractLink(nvim, line);

  if (!link) {
    return null;
  }

  if (link.url?.startsWith("./")) {
    link.url = path.join(await nvim.getVar("zortex_notes_dir"), link.url);
  }
  nvim.command(
    `let @a='${Math.floor(Math.random() * 1000)}${JSON.stringify(link)}'`,
  );

  if (filename === "zortex-structures" && link.type === "text") {
    const lines = await nvim.buffer.lines;
    openStructure(nvim, lines, link.name, link.indent);
  } else if (filename === "structure" && link.type === "text") {
    const lines = await readZortexLines(nvim, "structure.zortex");
    const opened = await openStructure(nvim, lines, link.name, link.indent);
    if (!opened) {
      open(`https://en.wikipedia.org/wiki/Special:Search/${link.name}`);
    }
  } else if (filename === "schedule" && link.type === "text") {
    openProject(nvim, link.name);
  } else if (link.type === "wikipedia" || link.type === "text") {
    if (link.name) {
      openArticle(nvim, link.name);
      // open(`https://en.wikipedia.org/wiki/Special:Search/${link.name}`)
    }
  } else if (link.type === "path") {
    if (fs.lstatSync(link.path.replace(/^~/, os.homedir()))?.isDirectory()) {
      nvim.command(`edit ${link.path}`);
    } else {
      nvim.command(`edit ${link.path}`);
    }
  } else if (link.type === "fragment-link") {
    // // move cursor forward one line to skip any matches of current line
    // let pos = await nvim.eval(`getpos(".")[1]]`)
    // pos += 1
    // nvim.command(`call cursor(${pos}, 1)`)

    nvim.command(`call search('\\c\s*- ${link.fragment}', 'sw')`);
    // } else if (link.type === 'zettel-link') {
    //   await nvim.command(`exec "edit " . expand("%:p:h") . "/zettels.zortex"`)
    //   nvim.command(`call search('^[${link.zettel_id}')`)
  } else if (link.type === "footernote") {
    nvim.command(`call search('[^${link.ref}]: ', 'b')`);
  } else if (link.type === "zortex-link") {
    open(link.url);
  } else if (
    link.type === "website" ||
    link.type === "resource" ||
    link.type === "file"
  ) {
    open(link.url);
  } else if (link.type === "article") {
    openArticle(nvim, link.name);
  } else if (link.type === "heading") {
    openArticle(nvim, link.name);
  }
}

module.exports = (plugin) => {
  const nvim = plugin.nvim;

  plugin.setOptions({
    dev: true,
    alwaysInit: true,
  });

  plugin.registerCommand(
    "ZortexSearchGoogle",
    (args) => {
      open(`https://www.google.com/search?q=${args.join(" ")}`);
    },
    {
      nargs: "*",
    },
  );
  plugin.registerCommand(
    "ZortexSearchWikipedia",
    (args) => {
      open(`https://en.wikipedia.org/wiki/Special:Search/${args.join(" ")}`);
    },
    {
      nargs: "*",
    },
  );
  plugin.registerCommand("ZortexOpenLink", () => openLink(nvim), {});

  // Needed to prevent errors from closing the rplugins connection
  process
    .on("unhandledRejection", (reason, p) => {
      // nvim.errWrite(`"${reason}"`)
      nvim.command(`let @a="${reason && reason.toString()}"`);
      console.error(reason, "Unhandled Rejection at Promise", p);
    })
    .on("uncaughtException", (err) => {
      // nvim.errWrite(`"${err.toString()}"`)
      nvim.command(`let @a="${err && err.toString()}"`);
      console.error(err, "Uncaught Exception thrown");
    });
};
