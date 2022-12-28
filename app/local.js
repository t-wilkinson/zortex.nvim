exports.run = () => {
  const { plugin } = require('./nvim')
  const logger = require('./lib/util/logger')('app/server')
  const server = require('./lib/server/local')
  server.run({plugin, logger})
}
