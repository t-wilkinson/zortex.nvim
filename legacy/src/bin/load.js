// This file is compiled into a small binary, which can run other files,
// without requiring nodejs on the system.

// change cwd to ./app
if (!/^(\/|C:\\)snapshot/.test(__dirname)) {
  process.chdir(__dirname)
} else {
  process.chdir(process.execPath.replace(/^(.*).bin.local-.*/, '$1'))
  // process.chdir(process.execPath.replace(/(zortex.nvim.*?app).+?$/, '$1'))
}

require('../app')
