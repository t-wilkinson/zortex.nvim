const { run } = require('../zortex/repl')

;(async () => {
  try {
    await run()
  } catch (e) {
    console.error(e)
  }
})()

