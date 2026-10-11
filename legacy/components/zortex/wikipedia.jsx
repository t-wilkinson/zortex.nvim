import React, { useState } from 'react';
import axios from 'axios';

export const WikipediaSearch = () => {
  const [searchTerm, setSearchTerm] = useState('');
  const [articles, setArticles] = useState([]);
  const [content, setContent] = useState('');

  const searchWikipedia = async () => {
    try {
      const response = await axios.get(`https://en.wikipedia.org/w/api.php`, {
        params: {
          action: 'query',
          list: 'search',
          srsearch: searchTerm,
          format: 'json',
          origin: '*'
        }
      });
      setArticles(response.data.query.search);
    } catch (error) {
      console.error('Error occurred while fetching data: ', error);
    }
  };

  const getArticleContent = async (title) => {
    try {
      const response = await axios.get(`https://en.wikipedia.org/w/api.php`, {
        params: {
          action: 'parse',
          page: title,
          format: 'json',
          origin: '*'
        }
      });
      setContent(response.data.parse.text['*']);
    } catch (error) {
      console.error('Error occurred while fetching content: ', error);
    }
  };

  return (
    <div className="App">
      <h1>Wikipedia Search</h1>
      <input
        type="text"
        value={searchTerm}
        onChange={(e) => setSearchTerm(e.target.value)}
        placeholder="Search Wikipedia"
      />
      <button onClick={searchWikipedia}>Search</button>

      <div className="search-results">
        <ul>
          {articles.map((article, index) => (
            <li key={index}>
              <button onClick={() => getArticleContent(article.title)}>
                {article.title}
              </button>
            </li>
          ))}
        </ul>
      </div>
      {content && (
        <div className="article-content">
          <h2>Article Content:</h2>
          <div dangerouslySetInnerHTML={{ __html: parseWikipediaTextToTree(content) }} />
        </div>
      )}
    </div>
  );
}
