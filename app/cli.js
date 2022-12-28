const { run } = require('./lib/zortex/cli')

;(async () => {
  try {
    await run()
  } catch (e) {
    console.error(e)
  }
})()
