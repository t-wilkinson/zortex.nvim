const withBundleAnalyzer = require('@next/bundle-analyzer')({
  enabled: process.env.ANALYZE === 'true',
})

module.exports = () => {

  return withBundleAnalyzer({
    pageExtensions: [ 'jsx' ],
    exportPathMap: async function () {
      return {
        '/buffer': { page: '/buffer' },
        '/wiki': { page: '/wiki' },
        '/404.html': { page: '/404' }
      }
    }
  })
}
