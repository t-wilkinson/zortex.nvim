import React from 'react'
import Head from 'next/head'

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

export default ({children}) => {
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
      .catch(err => {
        // console.error(err)
      })
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

