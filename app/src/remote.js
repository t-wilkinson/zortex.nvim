exports.run = () => {
  const server = require('./server/remote')
  // @ts-ignore
  const logger = require('./util/logger')('app/server')
  require('dotenv').config()

  require('process').chdir('../')
  server.run({logger})
}
