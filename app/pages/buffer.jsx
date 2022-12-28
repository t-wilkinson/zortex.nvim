import React from 'react'
import io from 'socket.io-client'

import Layout from '../components/layout'
import scrollToLine from '../components/scroll'
import {
  initMarkdown,
  chart,
  renderDiagram,
  renderFlowchart,
  renderDot
} from '../components/markdown'

const defaultContent = `@@Test
A@Tag1

test == test

[z-source]{type=website; resource=link; title=one; ref=https://youtube.com}
[z-source]{type=website; resource=image; title=one; ref=http://www.graphviz.org/Gallery/directed/bazel.svg}

% #z-reference#general#

10:20
  - hello

ABCDEFG.
    - Note 1
    ASDF.
      - Note 2

1. Test one
2. Test two

`

const testRefreshContentParams = {
  content: defaultContent.split('\n'),
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

const refreshRender = ({ newContent, refreshContent, md, state, setState, name }) => {
  setState({
    ...state,
    // name: ((name) => {
    //   let tokens = name.split(/\\|\//).pop().split('.')
    //   return tokens.length > 1 ? tokens.slice(0, -1).join('.') : tokens[0]
    // })(name),
    ...(refreshContent ? { content: md.render(newContent) } : {}),
  })
}

const Buffer = ({ md, options }) => {
  const [state, setState] = React.useState({
    content: [],
  })

  // socket functions
  React.useEffect(() => {
    let timer = undefined
    let preContent = ''

    const socket = io({
      query: {
        bufnr: window.location.pathname.split('/')[2],
      },
    })

    const onConnect = () => { console.log('connect success') }
    const onDisconnect = () => { console.log('disconnect') }
    const onClose = () => {
      console.log('close')
      window.closet()
    }
    const refreshContent = ({
      winline,
      winheight,
      content,
      cursor,
      isActive
    }) => {
      const newContent = content.join('\n')
      const refreshContent = preContent !== newContent
      preContent = newContent

      const refreshRenderProps = { newContent, refreshContent, state, setState, md }
      const refreshScrollProps = { winline, winheight, content, cursor, isActive, options }

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
  }, [state.refreshContent])

  return (
    <section
      className="markdown-body"
      dangerouslySetInnerHTML={{
        __html: state.content,
      }}
    />
  )
}

export default () => {
  const md = initMarkdown()

  return <Layout>
    <Buffer md={md} options={{}} />
  </Layout>
}
