const attach = require('./attach').default
// @ts-ignore
const logger = require('./util/logger')('src/nvim')

const MSG_PREFIX = '[zortex.nvim]'

const plugin = attach({
  reader: process.stdin,
  writer: process.stdout
})

process.on('uncaughtException', function (err) {
  let msg = `${MSG_PREFIX} uncaught exception: ` + err.stack
  if (plugin.nvim) {
    plugin.nvim.call('zortex#util#echo_messages', ['Error', msg.split('\n')])
  }
  logger.error('uncaughtException', err.stack)
})

process.on('unhandledRejection', function (reason, p) {
  if (plugin.nvim) {
    plugin.nvim.call('zortex#util#echo_messages', ['Error', [`${MSG_PREFIX} UnhandledRejection`, `${reason}`]])
  }
  logger.error('unhandledRejection ', p, reason)
})

exports.plugin = plugin
