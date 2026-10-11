import {Html, Head, Main, NextScript} from 'next/document'

export default function Document() {
  return (
    <Html>
      <Head>
        <link rel="stylesheet" href="/_static/page.css" />
        <link rel="stylesheet" href="/_static/zortex.css" />
        <link rel="stylesheet" href="/_static/markdown.css" />
        <link rel="stylesheet" href="/_static/highlight.css" />
        <link rel="stylesheet" href="/_static/katex@0.15.3.css" />
        <link rel="stylesheet" href="/_static/sequence-diagram-min.css" />
        <script type="text/javascript" src="/_static/tweenlite.min.js"></script>
        <script type="text/javascript" src="/_static/viz.js"></script>
        <script type="text/javascript" src="/_static/underscore-min.js"></script>
        <script type="text/javascript" src="/_static/webfont.js"></script>
        <script type="text/javascript" src="/_static/snap.svg.min.js"></script>
        <script type="text/javascript" src="/_static/mermaid.min.js"></script>
        <script type="text/javascript" src="/_static/sequence-diagram-min.js"></script>
        <script type="text/javascript" src="/_static/katex@0.15.3.js"></script>
        <script type="text/javascript" src="/_static/mhchem.min.js"></script>
        <script type="text/javascript" src="/_static/raphael@2.3.0.min.js"></script>
        <script type="text/javascript" src="/_static/flowchart@1.13.0.min.js"></script>
        <script type="text/javascript" src="/_static/full.render.js"></script>
      </Head>
      <body>
        <Main />
        <NextScript />
      </body>
    </Html>
  )
}
