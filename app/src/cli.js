const { run } = require('./zortex/cli')

;(async () => {
  try {
    await run()
  } catch (e) {
    console.error(e)
  }
})()
