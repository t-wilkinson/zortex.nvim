import React from 'react'
import io from 'socket.io-client'

import { Zortex, defaultContent } from '../components/zortex'
import Layout from '../components/layout'
import scrollToLine from '../components/scroll'
import {
  initMarkdown,
  chart,
  renderDiagram,
  renderFlowchart,
  renderDot
} from '../components/markdown'

const testRefreshContentParams = {
  markdownContent: '',
  content: process.env.NODE_ENV === 'development'
    ? defaultContent.split('\n')
    : [],
  isActive: true,
  winline: 1,
  winheight: 800,
  cursor: [1, 1],
  theme: 'light',
  name: 'Test',
}

const refreshScroll = ({
  winline,
  winheight,
  content,
  cursor,
  isActive,
  options,
}) => {
  if (isActive && !options.disable_sync_scroll) {
    scrollToLine[options.sync_scroll_type || 'middle']({
      cursor: cursor[1],
      winline,
      winheight,
      len: content.length,
    })
  }
}

const refreshRender = ({newContent, newMarkdownContent, refreshContent, md, state, setState, articleTitle}) => {
  setState({
    ...state,
    title: articleTitle?.title,
    slug: articleTitle?.slug,
    content: newContent,
    // name: ((name) => {
    //   let tokens = name.split(/\\|\//).pop().split('.')
    //   return tokens.length > 1 ? tokens.slice(0, -1).join('.') : tokens[0]
    // })(name),
    ...(refreshContent ? {markdownContent: md.render(newMarkdownContent)} : {}),
  })
}

const Buffer = ({md, options, setSlug, state, setState}) => {
  const socket = React.useMemo(() => io({
    reconnection: false,
    // reconnectionAttempts: 5,
  }), [])

  // socket functions
  React.useEffect(() => {
    let timer = undefined
    let preContent = ''
    let bufferLinksTimer = undefined

    const onConnect = () => {}
    const onDisconnect = () => {}
    const onClose = () => {
      console.log('close')
      window.closet()
    }
    const refreshContent = ({
      winline,
      winheight,
      content,
      cursor,
      isActive,
      articleTitle,
    }) => {
      const newContent = content.join('\n')
      const refreshContent = preContent !== newContent
      preContent = newContent
      setSlug(articleTitle?.slug)

      const refreshRenderProps = {newContent: content, newMarkdownContent: newContent, refreshContent, state, setState, md, articleTitle}
      const refreshScrollProps = {winline, winheight, content, cursor, isActive, options}

      if (!preContent) {
        refreshRender(refreshRenderProps)
        refreshScroll(refreshScrollProps)
      } else {
        if (!refreshContent) {
          refreshScroll(refreshScrollProps)
        } else {
          if (timer) {
            clearTimeout(timer)
          }
          if (bufferLinksTimer) {
            clearTimeout(bufferLinksTimer)
          }

          // can't reliably get this to work otherwise
          bufferLinksTimer = setTimeout(() => {
            const onPageChange = articleName => socket.emit('change_page', articleName)
            document.querySelectorAll('[data-z-article-name]')
              .forEach(elem => {
                const articleName = elem.getAttribute('data-z-article-name')
                elem.removeAttribute('data-z-article-name')
                elem.removeAttribute('href')

                elem.onclick = () => onPageChange(articleName)
                elem.classList.add('zortex-local-link')
              })
          }, 1000)

          timer = setTimeout(() => {
            refreshRender(refreshRenderProps)
            refreshScroll(refreshScrollProps)
          }, 16)
        }
      }
    }

    refreshContent(testRefreshContentParams)

    socket.on('connect', onConnect)
    socket.on('disconnect', onDisconnect)
    socket.on('close', onClose)
    socket.on('close_page', onClose)
    socket.on('refresh_content', refreshContent)
    socket.on('reconnect_error', () => {})
    socket.on('reconnect_attempt', () => {})
    socket.on('reconnect_failed', () => {})
    socket.on('error', () => {})
  }, [])

  React.useEffect(() => {
    try {
      // eslint-disable-next-line
      mermaid.initialize(options.maid || {})
      // eslint-disable-next-line
      mermaid.init(undefined, document.querySelectorAll('.mermaid'))
    } catch (e) {}

    chart.render()
    renderDiagram()
    renderFlowchart()
    renderDot()
  }, [state.content])

  return (
    <section
      className="markdown-body"
      dangerouslySetInnerHTML={{
        __html: state.markdownContent,
      }}
    />
  )
}

export default () => {
  const md = initMarkdown()
  const [slug, setSlug] = React.useState(null)
  const [state, setState] = React.useState({
    content: [],
    markdownContent: [],
  })

  return <Layout articleSlug={slug}>
    <Zortex md={md} text={state.content} />
    <Buffer
      md={md}
      options={{}}
      setSlug={setSlug}
      state={state}
      setState={setState}
    />
  </Layout>
}
