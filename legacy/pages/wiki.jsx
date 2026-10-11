import React from 'react'

import Layout from '../components/layout'
import {
  initMarkdown,
  chart,
  renderDiagram,
  renderFlowchart,
  renderDot
} from '../components/markdown'

const Wiki = ({md}) => {
  const [state, setState] = React.useState({
    content: [],
  })

  React.useEffect(() => {
    const articleName = window.location.pathname.split('/')[2]

    fetch(`/wiki/article/${articleName}`, {
      method: 'GET',
    })
      .then(res => res.json())
      .then(data => {
        if (!data?.content) {
          console.error('Could not find article. Received:', data)
        } else {
          setState({
            content: md.render(data.content.join('\n'))
          })
        }
      })
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
  }, [])

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
    <Wiki md={md} options={{}} />
  </Layout>
}
