exports.run = () => {
  const { plugin } = require('./nvim')
  const logger = require('./util/logger')('./server/local')
  const server = require('./server/local')

  require('process').chdir('../')
  server.run({plugin, logger})
}
