// change cwd to ./app
if (!/^(\/|C:\\)snapshot/.test(__dirname)) {
  process.chdir(__dirname)
} else {
  process.chdir(process.execPath.replace(/^(.*).bin.zortex-.*/, '$1'))
  // process.chdir(process.execPath.replace(/(zortex.nvim.*?app).+?$/, '$1'))
}

require('./lib/app')
