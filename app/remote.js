exports.run = () => {
  const server = require('./lib/server/remote')
  require('dotenv').config()
  server.run({})
}
