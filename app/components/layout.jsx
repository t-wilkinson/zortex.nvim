import React from 'react'
import Head from 'next/head'

// const defMatchingStructures = [{"root": {"text": "Projects", "slug": "Projects", "indent": 0, "isLink": true}, "tags": [], "structures": [{"text": "Me", "slug": "Me", "isLink": true, "indent": 4}, {"text": "Review", "slug": null, "isLink": false, "indent": 8}, {"text": "Refactor", "slug": null, "isLink": false, "indent": 8}, {"text": "Presentation", "slug": null, "isLink": false, "indent": 8}, {"text": "AI Presentation", "slug": "AI_Presentation", "isLink": true, "indent": 12}, {"text": "Talk", "slug": null, "isLink": false, "indent": 8}, {"text": "Spiritual growth", "slug": null, "isLink": false, "indent": 12}, {"text": "Projects", "slug": "Projects", "isLink": true, "indent": 8}, {"text": "Cognition", "slug": "Cognition", "isLink": true, "indent": 12}, {"text": "Artificial intelligence", "slug": null, "isLink": false, "indent": 16}, {"text": "Artificial general intelligence", "slug": "Artificial_general_intelligence", "isLink": true, "indent": 20}, {"text": "Deep learning", "slug": "Deep_learning", "isLink": true, "indent": 20}, {"text": "PyTorch", "slug": "PyTorch", "isLink": true, "indent": 20}, {"text": "MLOps", "slug": null, "isLink": false, "indent": 20}, {"text": "Neuroscience", "slug": "Neuroscience", "isLink": true, "indent": 16}, {"text": "Language", "slug": null, "isLink": false, "indent": 16}, {"text": "Cognitive science", "slug": "Cognitive_science", "isLink": true, "indent": 16}, {"text": "Music", "slug": "Music", "isLink": true, "indent": 12}, {"text": "Piano", "slug": null, "isLink": false, "indent": 16}, {"text": "Torrent", "slug": null, "isLink": false, "indent": 20}, {"text": "Moonlight Sonata", "slug": null, "isLink": false, "indent": 20}, {"text": "Moonlight Sonata third movement", "slug": null, "isLink": false, "indent": 20}, {"text": "Moonlight Sonata x Torrent", "slug": null, "isLink": false, "indent": 20}, {"text": "Un Sospiro", "slug": null, "isLink": false, "indent": 20}, {"text": "Piano technique", "slug": null, "isLink": false, "indent": 20}, {"text": "Guitar", "slug": null, "isLink": false, "indent": 16}, {"text": "Computer systems", "slug": null, "isLink": false, "indent": 12}, {"text": "Robotics", "slug": "Robotics", "isLink": true, "indent": 12}, {"text": "Fullstack", "slug": null, "isLink": false, "indent": 12}, {"text": "Clay 3D printer", "slug": null, "isLink": false, "indent": 16}, {"text": "Soccer robots", "slug": null, "isLink": false, "indent": 16}, {"text": "Website", "slug": null, "isLink": false, "indent": 12}, {"text": "Stake website", "slug": null, "isLink": false, "indent": 16}, {"text": "Shopping", "slug": null, "isLink": false, "indent": 8}, {"text": "Knowledge", "slug": null, "isLink": false, "indent": 8}, {"text": "Neuroscience", "slug": "Neuroscience", "isLink": true, "indent": 12}, {"text": "Metaphysics", "slug": null, "isLink": false, "indent": 12}, {"text": "Topos theory", "slug": "Topos_theory", "isLink": true, "indent": 12}, {"text": "Computation", "slug": "Computation", "isLink": true, "indent": 12}, {"text": "Health", "slug": "Health", "isLink": true, "indent": 8}, {"text": "Social", "slug": null, "isLink": false, "indent": 8}, {"text": "Spiritual", "slug": null, "isLink": false, "indent": 8}, {"text": "Relax", "slug": null, "isLink": false, "indent": 8}, {"text": "Learn", "slug": null, "isLink": false, "indent": 8}, {"text": "Neuroscience", "slug": "Neuroscience", "isLink": true, "indent": 12}, {"text": "Infinite Closet", "slug": "Infinite_Closet", "isLink": true, "indent": 4}, {"text": "Features", "slug": null, "isLink": false, "indent": 8}, {"text": "Charge more to items in high demand", "slug": null, "isLink": false, "indent": 12}, {"text": "Personalized recommendations", "slug": null, "isLink": false, "indent": 12}, {"text": "Accounts", "slug": null, "isLink": false, "indent": 12}, {"text": "Orders", "slug": null, "isLink": false, "indent": 12}, {"text": "Gift cards", "slug": null, "isLink": false, "indent": 12}, {"text": "Projects", "slug": "Projects", "isLink": true, "indent": 12}, {"text": "Shop", "slug": null, "isLink": false, "indent": 12}, {"text": "Sizing", "slug": null, "isLink": false, "indent": 12}, {"text": "Blogs", "slug": null, "isLink": false, "indent": 12}, {"text": "Virtual closet", "slug": null, "isLink": false, "indent": 12}, {"text": "Social media", "slug": null, "isLink": false, "indent": 12}, {"text": "My wardrobe", "slug": null, "isLink": false, "indent": 12}, {"text": "Monitoring", "slug": null, "isLink": false, "indent": 8}, {"text": "Website", "slug": null, "isLink": false, "indent": 8}, {"text": "DevOps", "slug": null, "isLink": false, "indent": 8}, {"text": "Business", "slug": "Business", "isLink": true, "indent": 8}, {"text": "Budget", "slug": null, "isLink": false, "indent": 8}, {"text": "LandDecorInc", "slug": "LandDecorInc", "isLink": true, "indent": 4}, {"text": "YSA", "slug": null, "isLink": false, "indent": 4}, {"text": "Zettelkasten", "slug": "Zettelkasten", "isLink": true, "indent": 4}, {"text": "Structure", "slug": "Structure", "isLink": true, "indent": 8}, {"text": "Memory palace", "slug": null, "isLink": false, "indent": 8}, {"text": "Wikipedia-like", "slug": null, "isLink": false, "indent": 8}, {"text": "Todo", "slug": null, "isLink": false, "indent": 8}, {"text": "Tags", "slug": null, "isLink": false, "indent": 8}]}]

const reducer = (state, action) => {
  switch (action.type) {
    case 'change-search-query':
      return {...state, searchQuery: action.searchQuery}
    case 'receive-search-results':
      return {...state, searchResults: action.articles}

    // theme
    case 'prefers-dark-theme':
      return {...state, theme: 'dark'}
    case 'handle-theme-change':
      return {...state, theme: state.theme === 'light' ? 'dark' : 'light'}

    // theme button
    case 'show-theme-button':
      return {...state, themeModeIsVisible: true}
    case 'hide-theme-button':
      return {...state, themeModeIsVisible: false}

    default:
      throw new Error(`Unknown action type: ${action.type}`)
  }
}

export default ({children, articleSlug}) => {
  const [state, dispatch] = React.useReducer(reducer, {
    name: '',
    searchQuery: '',
    searchResults: [],
    pageTitle: '',
    theme: '',
    themeModeIsVisible: true,
    disableFilename: 1,
    socket: null,
  })

  React.useEffect(() => {
    // Define the theme according to the preferences of the system
    if (!state.theme || !['light', 'dark'].includes(state.theme)) {
      if (
        window.matchMedia &&
        window.matchMedia('(prefers-color-scheme: dark)').matches
      ) {
        dispatch({type: 'prefers-dark-theme'})
      }
    }
  }, [])

  return (
    <React.Fragment>
      <Head>
        <title>{(state.pageTitle || '').replace(/\$\{name\}/, state.name)}</title>
        <link
          rel="shortcut icon"
          type="image/ico"
          href="/_static/favicon.ico"
        />
      </Head>
      <main data-theme={state.theme}>
        <div id="page-ctn">
          {state.disableFilename == 0 && (
            <Header
              state={state}
              dispatch={dispatch}
            />
          )}
          <Search state={state} dispatch={dispatch} />
          <Structures articleSlug={articleSlug} />
          {children}
        </div>
      </main>
    </React.Fragment>
  )
}

const Search = ({state, dispatch}) => {
  React.useEffect(() => {
    fetch(`/wiki/search?query=${state.searchQuery}`, {
      method: 'GET',
    })
      .then(res => res.json())
      .then(articles => dispatch({
        type: 'receive-search-results',
        articles,
      }))
      .catch(() => {})
  }, [state.searchQuery])

  return <div className="search">
    <div className="search__bar">
      <input
        type="search"
        className="search__input"
        value={state.searchQuery}
        onChange={e => dispatch({type: 'change-search-query', searchQuery: e.target.value})}
      />
      <button
        type="button"
        className="search__button"
      >
        Search
      </button>
    </div>
    {state.searchResults.length > 0 &&
      <div className="search__results">
        {state.searchResults.map((article, i) => <div key={article.fileName}>
          {i !== 0 && <div className="search__result-divider" />}
          <a
            className="search__result"
            href={`/wiki/${article.slug}`}
            data-z-article-name={article.title}
          >
            {article.title}
          </a>
        </div>)}
      </div>
    }
  </div>
}

const Header = ({state, dispatch}) => {
  return (
    <header
      id="page-header"
      onMouseEnter={() => dispatch({type: 'show-theme-button'})}
      onMouseLeave={() => dispatch({type: 'hide-theme-button'})}
    >
      <h3>
        <svg
          viewBox="0 0 16 16"
          version="1.1"
          width="16"
          height="16"
          aria-hidden="true"
        >
          <path
            fill-rule="evenodd"
            d="M3 5h4v1H3V5zm0 3h4V7H3v1zm0 2h4V9H3v1zm11-5h-4v1h4V5zm0 2h-4v1h4V7zm0 2h-4v1h4V9zm2-6v9c0 .55-.45 1-1 1H9.5l-1 1-1-1H2c-.55 0-1-.45-1-1V3c0-.55.45-1 1-1h5.5l1 1 1-1H15c.55 0 1 .45 1 1zm-8 .5L7.5 3H2v9h6V3.5zm7-.5H9.5l-.5.5V12h6V3z"
          ></path>
        </svg>
        {state.name}
      </h3>
      {state.themeModeIsVisible && (
        <label id="toggle-theme" for="theme">
          <input
            id="theme"
            type="checkbox"
            checked={state.theme === 'dark'}
            onChange={() => dispatch({type: 'handle-theme-change'})}
          />
          <span>Dark Mode</span>
        </label>
      )}
    </header>
  )
}

const Structures = ({articleSlug}) => {
  const [matchingStructures, setStructures] = React.useState([])

  React.useEffect(() => {
    if (articleSlug) {
      fetch(`/wiki/structures/${articleSlug}`)
        .then(data => data.json())
        .then(structures => {
          setStructures(structures)
        })
        .catch(() => {})
    }
  }, [articleSlug])

  return <div>
    {matchingStructures.map(({root, tags, structures}) =>
      <div key={root.text} style={{textAlign: 'center', fontSize: '10px', marginTop: '1rem'}}>
        <strong>{root.text} {tags.join('#')}</strong>
        <div>
          {structures.map((structure) =>
            <React.Fragment key={structure.text}>
              <StructureItem {...structure} />
              {' '}·{' '}
            </React.Fragment>
          )}
        </div>
      </div>
    )}
  </div>
}

const StructureItem = ({text, slug, indent, isLink}) => {
  const style = indent <= 4 ? {fontWeight: 'bold'} : {}
  return <>{isLink
    ? <a href={`/wiki/${slug}`} data-z-article-name={text}
      style={style}
    >{text}</a>
    : <span style={style}>{text}</span>}</>
}
