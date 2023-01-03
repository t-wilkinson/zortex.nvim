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

- [Test]

% #z-reference#general#

  - Represents a change of basis or coordinates encoding the notion that the basis vectors may change as a function of position in the vector field.

- Differential form
  - Recall that compact sets can be viewed as closed and bounded sets in a topological space.
  - For the following statements, let:
      - $D \\subset \\mathbb{R}^k$ be a compact set
      - $W \\subset \\mathbb{R}^k$ be a compact set and $D \\subset W$
      - $E \\subset \\mathbb{R}^n$ be an open set
  - If $f$ is a *$\\mathscr{C}$'-mapping* of $D$ into $\\mathbb{R}^n$ then there exists a $\\mathscr{C}$'-mapping $g$ which maps $W$ into $\\mathbb{R}^n$ such that $g(x)=f(x)$ for all $x \\in D$.
      - One can view a $f$ as embedding a compact set in $\\mathbb{R}^n$.
  - A *k-surface* in $E$ is a $\\mathscr{C}$'-mapping $\\phi$ from $D$ into $E$
      - $D$ is called the parameter domain of $\\phi$

  - A *differential form of order $k \\ge 1$ in $E$* (a *k-form in $E$*) is a function $\\omega$ which assigns to each $\\phi$ in $E$ a number $\\omega(\\phi) = \\int_\\phi \\omega$. $i_1, \\cdots, i_k$ range independently from 1 to $n$.
      $$\\omega = \\sum a_{i_1} \\cdots _{i_k}(\\mathbf{x})dx_{i_1} \\wedge \\cdots \\wedge dx_{i_k}$$
      $$\\int_\\phi \\omega = \\int_D \\sum a_{i_1} \\cdots _{i_k}(\\mathbf{\\Phi}(\\mathbf{u})) \\frac{\\partial(x_{i_1},\\cdots,x_{i_k})}{\\partial(u_1,\\cdots,u_{k})} d\\mathbf{u}$$
      $$\\int_{\\Omega}d\\omega = \\int_{\\partial\\Omega}\\omega$$

10:20
    - hello

A.
    - x
    AA.
      - x

B.
    - x
    - x
C.
    CA.
        CAA.
            - x
            - x

D.
    - x

    DA.
      - x


1. Test one
2. Test two

- [z-source]{type=website; resource=link; title=one; ref=https://youtube.com}
- {type=website; resource=image; title=one; ref=http://www.graphviz.org/Gallery/directed/bazel.svg}

`

const testRefreshContentParams = {
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

const refreshRender = ({newContent, refreshContent, md, state, setState, articleTitle}) => {
  setState({
    ...state,
    title: articleTitle?.title,
    slug: articleTitle?.slug,
    // name: ((name) => {
    //   let tokens = name.split(/\\|\//).pop().split('.')
    //   return tokens.length > 1 ? tokens.slice(0, -1).join('.') : tokens[0]
    // })(name),
    ...(refreshContent ? {content: md.render(newContent)} : {}),
  })
}

const Buffer = ({md, options, setSlug}) => {
  const [state, setState] = React.useState({
    content: [],
  })
  const socket = React.useMemo(() => io(), [])

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

      const refreshRenderProps = {newContent, refreshContent, state, setState, md, articleTitle}
      const refreshScrollProps = {winline, winheight, content, cursor, isActive, options}

      if (!preContent) {
        refreshRender(refreshRenderProps)
        refreshScroll(refreshScrollProps)
      } else {
        if (!refreshContent) {
          refreshScroll(refreshScrollProps)
        } else {
          setSlug(articleTitle?.slug)
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
  const [slug, setSlug] = React.useState(null)

  return <Layout articleSlug={slug}>
    <Buffer md={md} options={{}} setSlug={setSlug} />
  </Layout>
}
