exports.run = () => {
  const server = require('./lib/server/remote')
  const logger = require('./lib/util/logger')('app/server')
  require('dotenv').config()
  server.run({logger})
}
