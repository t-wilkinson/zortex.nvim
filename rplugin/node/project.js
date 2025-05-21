const zettelRE = /^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(?<text>.*)$/;
const projectRE = /^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(.*)$/;

/*
 * check if project is nested in another project
 * @returns {string} nested project name
 */
export async function findParentProjectName(nvim) {
  const pos = await nvim.eval(`getpos(".")[1]`);
  const indent = Number(await nvim.eval(`indent(${pos})`));

  // search backwards for parent project
  for (let currentPos = pos; currentPos > 0; currentPos--) {
    // looking for parent line
    const currentIndent = Number(await nvim.eval(`indent(${currentPos})`));
    if (currentIndent >= indent) {
      continue;
    }

    const line = await nvim.eval(`getline(${currentPos})`);

    // skip line if it is empty
    if (line === "") {
      continue;
    }

    const match = line.match(projectRE);
    if (!match) {
      break;
    }

    const parentProjectName = match[3];
    return parentProjectName;
  }

  return null;
}

/**
 * Find lineNumber of project in projects file
 *
 * @returns {number} line number of project in projects file
 */
export async function findProjectLineNumber(
  nvim,
  projectName,
  startLineNumber = 1,
  indent = 0,
) {
  const notesDir = await nvim.eval(`g:zortex_notes_dir`);
  let lineNumber = 0;

  const spaceRE = /\S|$/;
  const lines = readLines(path.join(notesDir, "projects.zortex"));
  for await (const line of lines) {
    lineNumber++;

    if (lineNumber < startLineNumber) {
      continue;
    }

    if (line === "") {
      continue;
    }

    const currentIndent = line.search(spaceRE);
    // skip nested lines
    if (currentIndent > indent) {
      continue;
    }

    // we are now outside of the project
    if (currentIndent < indent) {
      return null;
    }

    const match = line.match(projectRE);
    if (!match) {
      continue;
    }
    if (articleNamesMatch(projectName, match[3])) {
      return lineNumber;
    }
  }
}

export async function openProject(nvim, projectName) {
  const notesDir = await nvim.eval(`g:zortex_notes_dir`);
  const projectsFile = path.join(notesDir, "projects.zortex");
  let startLineNumber = 1;
  let indentsize = 0;
  let parentProjectName, parentLineNumber;

  // find starting line of parent project
  const currentIndent = Number(await nvim.eval(`indent(line("."))`));
  if (currentIndent > 0) {
    parentProjectName = await findParentProjectName(nvim);
    if (parentProjectName) {
      parentLineNumber = await findProjectLineNumber(nvim, parentProjectName);
      if (parentLineNumber) {
        indentsize = await nvim.eval(`&tabstop`);
        startLineNumber = parentLineNumber + 1;
      }
    }
  }

  // set search register to project name to search for matching tags
  const normalizedName = normalizeArticleName(projectName)
    .replace(/\s+/g, "-")
    .replace(/\\/g, "\\\\")
    .replace(/\//g, "\\/");
  const searchTerm = `#${normalizedName}#\|^\s*- ${projectName}`;
  nvim.command(`let @/ = '${searchTerm}'`);

  // goto line of project
  const lineNumber = await findProjectLineNumber(
    nvim,
    projectName,
    startLineNumber,
    indentsize,
  );
  if (lineNumber) {
    await nvim.command(`edit +${lineNumber} ${projectsFile}`);
  } else if (parentProjectName && parentLineNumber) {
    await nvim.command(`edit +${parentLineNumber} ${projectsFile}`);
  } else {
    await nvim.command(`edit +/${searchTerm} ${projectsFile}`);
  }
  // await nvim.input('n')
}

export async function openStructure(nvim, lines, structureName, indent) {
  const cursorLineNumber = await nvim.eval(`line(".")`);
  let lineNumber = 0;
  let articleName = null;

  for await (const line of lines) {
    lineNumber++;

    if (lineNumber > cursorLineNumber) {
      break;
    }

    if (line === "") {
      continue;
    }

    const currentIndent = line.search(/\S|$/);
    if (currentIndent >= indent) {
      continue;
    }
    const match = line.match(articleLinkRE);
    if (!match) {
      continue;
    }
    articleName = match[1];
  }

  if (!articleName) {
    return;
  }

  const filePath = await getArticlePath(nvim, articleName);
  lineNumber = 0;
  for await (const line of readLines(filePath)) {
    lineNumber++;

    const match = line.match(zettelRE);
    if (!match) {
      continue;
    }

    if (articleNamesMatch(match[3], structureName)) {
      await nvim.command(`edit ${filePath}`);
      await nvim.command(`normal! ${lineNumber}G`);
      return true;
    }
  }
}
